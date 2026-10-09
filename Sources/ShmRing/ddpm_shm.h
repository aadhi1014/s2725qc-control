// Shared-memory audio ring between the S2725QC driver (writer, inside coreaudiod)
// and the DDPM agent (reader). Replaces the loopback input stream, so no process
// ever captures audio and macOS shows no microphone indicator.
#ifndef DDPM_SHM_H
#define DDPM_SHM_H

#include <stdatomic.h>
#include <stdint.h>

#define DDPM_SHM_NAME      "/dev.solderable.s2725qc"
#define DDPM_SHM_MAGIC     0x44445043u /* 'DDPC' */
#define DDPM_SHM_VERSION   1u
#define DDPM_SHM_CHANNELS  2u
#define DDPM_SHM_CAPACITY  16384u /* frames, power of two */

typedef struct {
    uint32_t magic;
    uint32_t version;
    uint32_t channels;
    uint32_t capacity;
    /// Device sample time just past the last frame written. Resets when the device restarts IO.
    _Atomic int64_t writeEnd;
    float data[DDPM_SHM_CAPACITY * DDPM_SHM_CHANNELS];
} DDPMShm;

#endif
