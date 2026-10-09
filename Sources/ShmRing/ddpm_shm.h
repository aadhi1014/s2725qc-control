// Shared-memory audio ring between the S2725QC driver (writer, inside coreaudiod)
// and the DDPM agent (reader). Replaces the loopback input stream, so no process
// ever captures audio and macOS shows no microphone indicator.
#ifndef DDPM_SHM_H
#define DDPM_SHM_H

#include <stdatomic.h>
#include <stdint.h>

// POSIX shm objects can't be resized on macOS, so the name changes with the layout.
#define DDPM_SHM_NAME      "/dev.solderable.s2725qc.3"
#define DDPM_SHM_MAGIC     0x44445043u /* 'DDPC' */
#define DDPM_SHM_VERSION   3u
/// Quad: front left, front right, left surround, right surround.
#define DDPM_SHM_CHANNELS  4u
#define DDPM_SHM_CAPACITY  16384u /* frames, power of two */
/// Fixed delay between the virtual device's clock and the monitors (43 ms at 48 kHz). It covers
/// the monitors' own output lead plus the smallest app buffers, and the driver reports it to
/// apps as device latency so video players keep lip-sync.
#define DDPM_LATENCY_FRAMES 2048u

typedef struct {
    uint32_t magic;
    uint32_t version;
    uint32_t channels;
    uint32_t capacity;
    /// Device sample time just past the last frame written. Resets when the device restarts IO.
    _Atomic int64_t writeEnd;
    /// The virtual device's clock: sample time s plays at host time anchorHostTime + s * hostTicksPerFrame.
    /// Written before writeEnd (release), so a reader that sees writeEnd sees the matching clock.
    _Atomic uint64_t anchorHostTime;
    _Atomic double hostTicksPerFrame;
    float data[DDPM_SHM_CAPACITY * DDPM_SHM_CHANNELS];
} DDPMShm;

#endif
