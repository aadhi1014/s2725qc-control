// Reader half of the shared ring, used by the agent's output IOProc.
#ifndef DDPM_READER_H
#define DDPM_READER_H

#include <CoreAudio/CoreAudioTypes.h>
#include <stdbool.h>

/// Maps the ring published by the driver. Returns false if the driver hasn't created it.
bool ddpm_reader_open(void);

/// Fills `output` from the ring with drift correction; silence when nothing is playing. Real-time safe.
void ddpm_reader_render(AudioBufferList *output, UInt32 frames);

#endif
