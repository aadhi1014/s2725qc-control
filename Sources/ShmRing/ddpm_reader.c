#include "ddpm_reader.h"
#include "ddpm_shm.h"

#include <fcntl.h>
#include <math.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

// Timing: the driver publishes its clock (sample time s plays at anchor + s * ticksPerFrame).
// For each output buffer, the monitor's IOProc says at which host time it will be presented;
// the reader plays the sample that belongs to that moment, DDPM_LATENCY_FRAMES late. Every
// monitor therefore plays each sample at the same instant, independent of when playback
// started, and per-speaker calibration delays stay valid. A slow rate correction (at most
// kMaxRateDelta, inaudible) keeps the read position on that target as the monitor's clock drifts.
static const double kMaxRateDelta = 0.002;
static const double kRateGain = 2e-5;      // rate correction per frame of timing error
static const double kResyncError = 512.0;  // jump instead of correcting when this far off

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
    bool locked;      ///< readPos is tracking the clock identified by `anchor`.
    uint64_t anchor;
    double readPos;
    float delay[2];   ///< Calibration delay per speaker (0 = left, 1 = right), in frames.
};

DDPMReader *ddpm_reader_create(DDPMRole role)
{
    DDPMReader *reader = calloc(1, sizeof(DDPMReader));
    reader->role = role;
    return reader;
}

void ddpm_reader_destroy(DDPMReader *reader)
{
    free(reader);
}

void ddpm_reader_set_delays(DDPMReader *reader, float leftFrames, float rightFrames)
{
    reader->delay[0] = fmaxf(0, fminf(leftFrames, DDPM_SHM_CAPACITY / 4));
    reader->delay[1] = fmaxf(0, fminf(rightFrames, DDPM_SHM_CAPACITY / 4));
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

void ddpm_reader_render(DDPMReader *reader, AudioBufferList *output, UInt32 frames, UInt64 outputHostTime)
{
    const DDPMShm *shm = gShm;
    if (!shm || output->mNumberBuffers == 0 || !output->mBuffers[0].mData) {
        if (output) silence(output);
        return;
    }
    int64_t writeEnd = atomic_load_explicit((_Atomic int64_t *)&shm->writeEnd, memory_order_acquire);
    uint64_t anchor = atomic_load_explicit((_Atomic uint64_t *)&shm->anchorHostTime, memory_order_relaxed);
    double ticksPerFrame = atomic_load_explicit((_Atomic double *)&shm->hostTicksPerFrame, memory_order_relaxed);
    if (ticksPerFrame <= 0 || outputHostTime < anchor) {
        reader->locked = false;
        silence(output);
        return;
    }

    // The sample that should be heard when this buffer is presented.
    double target = (double)(outputHostTime - anchor) / ticksPerFrame - DDPM_LATENCY_FRAMES;
    if (!reader->locked || anchor != reader->anchor || fabs(reader->readPos - target) > kResyncError) {
        reader->readPos = target;
        reader->anchor = anchor;
        reader->locked = true;
    }
    double rate = 1.0 - fmax(-kMaxRateDelta, fmin(kMaxRateDelta, (reader->readPos - target) * kRateGain));

    // Everything this buffer reads must already be written and not yet overwritten;
    // otherwise playback stopped (or hasn't caught up), so stay silent.
    double maxDelay = fmaxf(reader->delay[0], reader->delay[1]);
    double newest = reader->readPos + frames * rate + 1;
    double oldest = reader->readPos - maxDelay - 1;
    if (newest >= (double)writeEnd || oldest < (double)(writeEnd - (int64_t)DDPM_SHM_CAPACITY)) {
        reader->readPos += frames; // keep following the clock
        silence(output);
        return;
    }

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
        if (reader->rearMix < rearTarget) reader->rearMix = fminf(rearTarget, reader->rearMix + kRearFadeStep);
        if (reader->rearMix > rearTarget) reader->rearMix = fmaxf(rearTarget, reader->rearMix - kRearFadeStep);
        for (UInt32 c = 0; c < channels; c++) {
            UInt32 sp = c < 2 ? c : 1;
            double p = pos - reader->delay[sp];
            int64_t i0 = (int64_t)floor(p);
            float frac = (float)(p - (double)i0);
            const float *a = &shm->data[((uint64_t)i0 & mask) * DDPM_SHM_CHANNELS];
            const float *b = &shm->data[((uint64_t)(i0 + 1) & mask) * DDPM_SHM_CHANNELS];
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
