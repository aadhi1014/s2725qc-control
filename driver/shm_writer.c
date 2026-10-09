// Writer half of the shared ring: linked into the driver, called from BlackHole.c (see driver/build.sh).
#include "../Sources/ShmRing/ddpm_shm.h"

#include <CoreAudio/CoreAudioTypes.h>
#include <errno.h>
#include <fcntl.h>
#include <stdbool.h>
#include <os/log.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

static DDPMShm *gShm = NULL;

/// Creates/maps the shared ring. Idempotent; never called on the IO thread.
void ShmRing_Init(void)
{
    if (gShm) return;
    int fd = shm_open(DDPM_SHM_NAME, O_CREAT | O_RDWR, 0644);
    if (fd < 0) {
        os_log_error(OS_LOG_DEFAULT, "S2725QC: shm_open failed: %{errno}d", errno);
        return;
    }
    fchmod(fd, 0644);
    struct stat st;
    // macOS only allows sizing a POSIX shm object once.
    if (fstat(fd, &st) == 0 && st.st_size < (off_t)sizeof(DDPMShm) && ftruncate(fd, sizeof(DDPMShm)) != 0) {
        os_log_error(OS_LOG_DEFAULT, "S2725QC: ftruncate failed: %{errno}d", errno);
        close(fd);
        return;
    }
    void *p = mmap(NULL, sizeof(DDPMShm), PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    close(fd);
    if (p == MAP_FAILED) {
        os_log_error(OS_LOG_DEFAULT, "S2725QC: mmap failed: %{errno}d", errno);
        return;
    }
    DDPMShm *shm = p;
    shm->magic = DDPM_SHM_MAGIC;
    shm->version = DDPM_SHM_VERSION;
    shm->channels = DDPM_SHM_CHANNELS;
    shm->capacity = DDPM_SHM_CAPACITY;
    atomic_store_explicit(&shm->writeEnd, 0, memory_order_release);
    gShm = shm;
    os_log(OS_LOG_DEFAULT, "S2725QC: shared ring ready");
}

/// Copies one mixed output buffer (interleaved stereo float) into the ring. Real-time safe.
void ShmRing_Write(const Float32 *buffer, UInt32 frames, Float64 sampleTime, bool mute)
{
    DDPMShm *shm = gShm;
    if (!shm) return;
    int64_t start = (int64_t)sampleTime;
    const uint32_t mask = DDPM_SHM_CAPACITY - 1;
    for (UInt32 f = 0; f < frames; f++) {
        float *dst = &shm->data[((uint64_t)(start + f) & mask) * DDPM_SHM_CHANNELS];
        if (mute) {
            dst[0] = 0; dst[1] = 0;
        } else {
            dst[0] = buffer[f * 2]; dst[1] = buffer[f * 2 + 1];
        }
    }
    atomic_store_explicit(&shm->writeEnd, start + frames, memory_order_release);
}
