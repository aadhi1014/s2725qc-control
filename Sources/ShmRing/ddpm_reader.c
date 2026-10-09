#include "ddpm_reader.h"
#include "ddpm_shm.h"

#include <fcntl.h>
#include <math.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

// The virtual device and the monitor run on independent clocks, and the driver writes in
// chunks whose size the playing app picks (512 frames for most apps; Safari uses 4096).
// Between two chunks the reader's backlog drops by a full chunk, so it must start each
// chunk at least (chunk + one reader buffer + margin) behind the writer or it runs dry.
// The reader measures the chunk size, aims its average backlog at the middle of that
// sawtooth, and nudges its playback rate (by at most kMaxRateDelta, inaudible) to hold
// it there as the clocks drift apart.
static const double kMinChunk = 512.0;
static const double kMargin = 384.0;
static const double kMaxRateDelta = 0.002;
static const double kRateGain = 0.0005 / 512.0;

static const DDPMShm *gShm = NULL;

enum { kL = 0, kR = 1, kLs = 2, kRs = 3 };
static const float kRearSilence = 1e-5f;
// Rear channels count as active for 10 s after their last sound, so quiet moments in
// surround content don't flip the rear speakers to the front copy.
static const int64_t kRearHoldFrames = 48000 * 10;
static const float kRearFadeStep = 1.0f / 4800; // 100 ms crossfade between front copy and discrete rear

struct DDPMReader {
    DDPMRole role;
    int64_t rearHold; ///< Frames left during which the rear channels count as active.
    float rearMix;    ///< 0 = rear speakers copy the front channel, 1 = they play the rear channel.
    bool active;
    double readPos;
    double fillAvg;
    int64_t lastIdleWrite;
    int64_t lastWriteEnd;
    double chunk; ///< Largest writer step recently seen; decays slowly. Kept across idle periods.
};

DDPMReader *ddpm_reader_create(DDPMRole role)
{
    DDPMReader *reader = calloc(1, sizeof(DDPMReader));
    reader->role = role;
    reader->lastIdleWrite = -1;
    reader->chunk = kMinChunk;
    return reader;
}

void ddpm_reader_destroy(DDPMReader *reader)
{
    free(reader);
}

bool ddpm_ring_open(void)
{
    if (gShm) return true;
    int fd = shm_open(DDPM_SHM_NAME, O_RDONLY);
    if (fd < 0) return false;
    void *p = mmap(NULL, sizeof(DDPMShm), PROT_READ, MAP_SHARED, fd, 0);
    close(fd);
    if (p == MAP_FAILED) return false;
    const DDPMShm *shm = p;
    if (shm->magic != DDPM_SHM_MAGIC || shm->version != DDPM_SHM_VERSION) {
        munmap(p, sizeof(DDPMShm));
        return false;
    }
    gShm = shm;
    return true;
}

static void silence(AudioBufferList *output)
{
    for (UInt32 i = 0; i < output->mNumberBuffers; i++) {
        if (output->mBuffers[i].mData) memset(output->mBuffers[i].mData, 0, output->mBuffers[i].mDataByteSize);
    }
}

/// Backlog right after a chunk arrives: enough to last until the next one.
static double startFill(const DDPMReader *reader, UInt32 frames)
{
    return reader->chunk + frames + kMargin;
}

/// Average backlog over the writer's sawtooth (from startFill down to startFill - chunk).
static double targetFill(const DDPMReader *reader, UInt32 frames)
{
    return startFill(reader, frames) - reader->chunk / 2;
}

static void trackChunk(DDPMReader *reader, int64_t writeEnd)
{
    int64_t step = writeEnd - reader->lastWriteEnd;
    reader->lastWriteEnd = writeEnd;
    if (step > 0 && step <= DDPM_SHM_CAPACITY / 4) {
        if (step > reader->chunk) reader->chunk = (double)step;
    }
    // Decay toward the smallest chunk over ~30 s so latency shrinks again after a big-chunk app stops.
    reader->chunk = fmax(kMinChunk, reader->chunk * 0.99995);
}

void ddpm_reader_render(DDPMReader *reader, AudioBufferList *output, UInt32 frames)
{
    const DDPMShm *shm = gShm;
    if (!shm || output->mNumberBuffers == 0 || !output->mBuffers[0].mData) {
        if (output) silence(output);
        return;
    }
    int64_t writeEnd = atomic_load_explicit((_Atomic int64_t *)&shm->writeEnd, memory_order_acquire);
    trackChunk(reader, writeEnd);

    if (!reader->active) {
        // Wait until the writer produces new audio, then start far enough behind it.
        if (writeEnd == reader->lastIdleWrite || writeEnd < (int64_t)startFill(reader, frames)) {
            reader->lastIdleWrite = writeEnd;
            silence(output);
            return;
        }
        reader->readPos = (double)writeEnd - startFill(reader, frames);
        reader->fillAvg = targetFill(reader, frames);
        reader->active = true;
    }

    double fill = (double)writeEnd - reader->readPos;
    if (fill < 0 || fill > DDPM_SHM_CAPACITY - 2.0 * frames) {
        // Writer restarted (sample time reset) or we fell far behind: resync.
        reader->readPos = (double)writeEnd - startFill(reader, frames);
        reader->fillAvg = targetFill(reader, frames);
        fill = startFill(reader, frames);
    }
    if (fill < frames * (1.0 + kMaxRateDelta) + 2.0) {
        // Writer stopped (playback ended). Go idle until it advances again.
        reader->active = false;
        reader->lastIdleWrite = writeEnd;
        silence(output);
        return;
    }

    reader->fillAvg += (fill - reader->fillAvg) * 0.01;
    double rate = 1.0 + fmax(-kMaxRateDelta, fmin(kMaxRateDelta, (reader->fillAvg - targetFill(reader, frames)) * kRateGain));

    const uint32_t mask = DDPM_SHM_CAPACITY - 1;

    // Are the rear channels carrying their own sound? (Stereo apps leave them silent.)
    for (UInt32 f = 0; f <= frames; f++) {
        const float *frame = &shm->data[((uint64_t)((int64_t)reader->readPos + f) & mask) * DDPM_SHM_CHANNELS];
        if (fabsf(frame[kLs]) > kRearSilence || fabsf(frame[kRs]) > kRearSilence) {
            reader->rearHold = kRearHoldFrames;
            break;
        }
    }
    float rearTarget = reader->rearHold > 0 ? 1.0f : 0.0f;
    if (reader->rearHold > 0) reader->rearHold -= frames;

    // For each of the monitor's speakers (0 = left, 1 = right): front channel, and the rear
    // channel it crossfades to (-1 = front only). A single monitor mixes front and rear.
    int front[2], rear[2];
    bool sum = false;
    switch (reader->role) {
    case DDPMRoleLeftSide:  front[0] = kL; rear[0] = kLs; front[1] = kL; rear[1] = -1;  break;
    case DDPMRoleRightSide: front[0] = kR; rear[0] = -1;  front[1] = kR; rear[1] = kRs; break;
    default:                front[0] = kL; rear[0] = kLs; front[1] = kR; rear[1] = kRs; sum = true; break;
    }

    // Interleaved float output; the monitor's stream is the first buffer.
    AudioBuffer *buf = &output->mBuffers[0];
    UInt32 channels = buf->mNumberChannels;
    float *dst = buf->mData;
    double pos = reader->readPos;
    for (UInt32 f = 0; f < frames; f++) {
        int64_t i0 = (int64_t)floor(pos);
        float frac = (float)(pos - (double)i0);
        const float *a = &shm->data[((uint64_t)i0 & mask) * DDPM_SHM_CHANNELS];
        const float *b = &shm->data[((uint64_t)(i0 + 1) & mask) * DDPM_SHM_CHANNELS];
        if (reader->rearMix < rearTarget) reader->rearMix = fminf(rearTarget, reader->rearMix + kRearFadeStep);
        if (reader->rearMix > rearTarget) reader->rearMix = fmaxf(rearTarget, reader->rearMix - kRearFadeStep);
        for (UInt32 c = 0; c < channels; c++) {
            UInt32 sp = c < 2 ? c : 1;
            float va = a[front[sp]], vb = b[front[sp]];
            if (rear[sp] >= 0) {
                float ra = a[rear[sp]], rb = b[rear[sp]];
                if (sum) {
                    va += ra; vb += rb;
                } else {
                    float m = reader->rearMix;
                    va += (ra - va) * m; vb += (rb - vb) * m;
                }
            }
            dst[f * channels + c] = va + (vb - va) * frac;
        }
        pos += rate;
    }
    reader->readPos = pos;
    for (UInt32 i = 1; i < output->mNumberBuffers; i++) {
        if (output->mBuffers[i].mData) memset(output->mBuffers[i].mData, 0, output->mBuffers[i].mDataByteSize);
    }
}

