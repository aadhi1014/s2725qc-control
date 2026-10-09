// Reader half of the shared ring, used by the agent's output IOProcs (one reader per monitor).
#ifndef DDPM_READER_H
#define DDPM_READER_H

#include <CoreAudio/CoreAudioTypes.h>
#include <stdbool.h>

/// Which part of the stereo signal a monitor plays.
typedef enum {
    DDPMChannelStereo = -1, ///< L/R to the monitor's own left/right speakers.
    DDPMChannelLeft = 0,    ///< Left channel on all of the monitor's speakers.
    DDPMChannelRight = 1,   ///< Right channel on all of the monitor's speakers.
} DDPMChannel;

typedef struct DDPMReader DDPMReader;

/// Maps the ring published by the driver. Returns false if the driver hasn't created it.
bool ddpm_ring_open(void);

DDPMReader *ddpm_reader_create(DDPMChannel channel);
void ddpm_reader_destroy(DDPMReader *reader);

/// Fills `output` from the ring with drift correction; silence when nothing is playing. Real-time safe.
void ddpm_reader_render(DDPMReader *reader, AudioBufferList *output, UInt32 frames);

#endif
