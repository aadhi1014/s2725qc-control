#include "ddpm_reader.h"
#include "ddpm_shm.h"

#include <fcntl.h>
#include <math.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

// The virtual device and the monitor run on independent clocks. The reader stays
// kTargetFill frames behind the writer and nudges its playback rate (by at most
// kMaxRateDelta, inaudible) to hold that distance as the clocks drift apart.
static const double kTargetFill = 2048.0;   // ~43 ms at 48 kHz
static const double kMaxRateDelta = 0.002;
static const double kRateGain = 0.0005 / 512.0;

static const DDPMShm *gShm = NULL;

struct DDPMReader {
    DDPMChannel channel;
    bool active;
    double readPos;
    double fillAvg;
    int64_t lastIdleWrite;
};

DDPMReader *ddpm_reader_create(DDPMChannel channel)
{
    DDPMReader *reader = calloc(1, sizeof(DDPMReader));
    reader->channel = channel;
    reader->lastIdleWrite = -1;
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

void ddpm_reader_render(DDPMReader *reader, AudioBufferList *output, UInt32 frames)
{
    const DDPMShm *shm = gShm;
    if (!shm || output->mNumberBuffers == 0 || !output->mBuffers[0].mData) {
        if (output) silence(output);
        return;
    }
    int64_t writeEnd = atomic_load_explicit((_Atomic int64_t *)&shm->writeEnd, memory_order_acquire);

    if (!reader->active) {
        // Wait until the writer produces new audio, then start kTargetFill behind it.
        if (writeEnd == reader->lastIdleWrite || writeEnd < (int64_t)kTargetFill) {
            reader->lastIdleWrite = writeEnd;
            silence(output);
            return;
        }
        reader->readPos = (double)writeEnd - kTargetFill;
        reader->fillAvg = kTargetFill;
        reader->active = true;
    }

    double fill = (double)writeEnd - reader->readPos;
    if (fill < 0 || fill > DDPM_SHM_CAPACITY - 2.0 * frames) {
        // Writer restarted (sample time reset) or we fell far behind: resync.
        reader->readPos = (double)writeEnd - kTargetFill;
        reader->fillAvg = kTargetFill;
        fill = kTargetFill;
    }
    if (fill < frames * (1.0 + kMaxRateDelta) + 2.0) {
        // Writer stopped (playback ended). Go idle until it advances again.
        reader->active = false;
        reader->lastIdleWrite = writeEnd;
        silence(output);
        return;
    }

    reader->fillAvg += (fill - reader->fillAvg) * 0.01;
    double rate = 1.0 + fmax(-kMaxRateDelta, fmin(kMaxRateDelta, (reader->fillAvg - kTargetFill) * kRateGain));

    // Interleaved float output; the monitor's stream is the first buffer.
    AudioBuffer *buf = &output->mBuffers[0];
    UInt32 channels = buf->mNumberChannels;
    float *dst = buf->mData;
    const uint32_t mask = DDPM_SHM_CAPACITY - 1;
    double pos = reader->readPos;
    for (UInt32 f = 0; f < frames; f++) {
        int64_t i0 = (int64_t)floor(pos);
        float frac = (float)(pos - (double)i0);
        const float *a = &shm->data[((uint64_t)i0 & mask) * DDPM_SHM_CHANNELS];
        const float *b = &shm->data[((uint64_t)(i0 + 1) & mask) * DDPM_SHM_CHANNELS];
        for (UInt32 c = 0; c < channels; c++) {
            UInt32 sc = reader->channel == DDPMChannelStereo ? (c < DDPM_SHM_CHANNELS ? c : DDPM_SHM_CHANNELS - 1)
                                                             : (UInt32)reader->channel;
            dst[f * channels + c] = a[sc] + (b[sc] - a[sc]) * frac;
        }
        pos += rate;
    }
    reader->readPos = pos;
    for (UInt32 i = 1; i < output->mNumberBuffers; i++) {
        if (output->mBuffers[i].mData) memset(output->mBuffers[i].mData, 0, output->mBuffers[i].mDataByteSize);
    }
}
