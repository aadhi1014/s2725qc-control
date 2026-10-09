// Reader half of the shared ring, used by the agent's output IOProcs (one reader per monitor).
#ifndef DDPM_READER_H
#define DDPM_READER_H

#include <CoreAudio/CoreAudioTypes.h>
#include <stdbool.h>

/// Which speakers of the quad layout (L, R, Ls, Rs) a monitor's two speakers play.
/// Rear speakers fall back to the front channel while the rear channels are silent,
/// which is the case for all stereo content.
typedef enum {
    DDPMRoleStereo,    ///< Single monitor: left speaker L+Ls, right speaker R+Rs.
    DDPMRoleLeftSide,  ///< Left monitor: outer (left) speaker Ls, inner (right) speaker L.
    DDPMRoleRightSide, ///< Right monitor: inner (left) speaker R, outer (right) speaker Rs.
} DDPMRole;

typedef struct DDPMReader DDPMReader;

/// Maps the ring published by the driver. Returns false if the driver hasn't created it.
bool ddpm_ring_open(void);

DDPMReader *ddpm_reader_create(DDPMRole role);
void ddpm_reader_destroy(DDPMReader *reader);

/// Fills `output` from the ring with drift correction; silence when nothing is playing. Real-time safe.
void ddpm_reader_render(DDPMReader *reader, AudioBufferList *output, UInt32 frames);

#endif
