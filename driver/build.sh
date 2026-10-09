#!/bin/zsh
# Builds S2725QC.driver: a BlackHole-based, output-only quad (L, R, Ls, Rs) virtual device with volume/mute controls.
# Mixed output is published through a POSIX shared-memory ring (shm_writer.c) instead of a
# loopback input stream, so the agent never captures audio. The agent plays the ring to the
# monitor and mirrors volume to it via DDC/CI.
set -e
cd "$(dirname "$0")"
OUT=build/S2725QC.driver
rm -rf "$OUT"
mkdir -p "$OUT/Contents/MacOS"

# Hook the ring writer into an unmodified copy of BlackHole.c.
python3 - ../vendor/BlackHole/BlackHole/BlackHole.c build/BlackHole.patched.c <<'PY'
import sys
src = open(sys.argv[1]).read()
def patch(old, new):
    global src
    assert src.count(old) == 1, f"patch anchor not found: {old[:60]!r}"
    src = src.replace(old, new)
patch('#include <CoreAudio/AudioServerPlugIn.h>',
      '#include <CoreAudio/AudioServerPlugIn.h>\n'
      'void ShmRing_Init(void);\n'
      'void ShmRing_Write(const Float32*, UInt32, Float64, bool);')
patch('static OSStatus\tBlackHole_Initialize(AudioServerPlugInDriverRef inDriver, AudioServerPlugInHostRef inHost)\n{',
      'static OSStatus\tBlackHole_Initialize(AudioServerPlugInDriverRef inDriver, AudioServerPlugInHostRef inHost)\n{\n\tShmRing_Init();')
patch('static OSStatus\tBlackHole_StartIO(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID)\n{',
      'static OSStatus\tBlackHole_StartIO(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID)\n{\n\tShmRing_Init();')
patch('''        // Save the last output time.
        lastOutputSampleTime''', '''        if (inDeviceObjectID == kObjectID_Device)
        {
            ShmRing_Write((const Float32*)ioMainBuffer, inIOBufferFrameSize, inIOCycleInfo->mOutputTime.mSampleTime, gMute_Master_Value);
        }

        // Save the last output time.
        lastOutputSampleTime''')
# Quad speaker layout (L, R, Ls, Rs) instead of BlackHole's default L, R, C, LFE labels.
patch('mChannelDescriptions[theItemIndex].mChannelLabel = kAudioChannelLabel_Left + theItemIndex;',
      'mChannelDescriptions[theItemIndex].mChannelLabel = (AudioChannelLabel[]){ kAudioChannelLabel_Left, kAudioChannelLabel_Right, kAudioChannelLabel_LeftSurround, kAudioChannelLabel_RightSurround }[theItemIndex];')
open(sys.argv[2], 'w').write(src)
PY

clang -O2 -bundle -arch arm64 -mmacosx-version-min=12.0 -w \
  -DkDriver_Name='"S2725QC"' \
  -DkPlugIn_BundleID='"dev.solderable.ddpm.S2725QC"' \
  -DkHas_Driver_Name_Format=false \
  -DkDevice_Name='"DELL S2725QC (DDC)"' \
  -DkManufacturer_Name='"Dell"' \
  -DkNumber_Of_Channels=4 \
  -DkDevice_HasInput=false \
  -DkDevice2_HasInput=false \
  -DkPlugIn_Icon='""' \
  -framework CoreAudio -framework CoreFoundation -framework Accelerate \
  build/BlackHole.patched.c shm_writer.c -o "$OUT/Contents/MacOS/S2725QC"
sed -e 's/${EXECUTABLE_NAME}/S2725QC/' \
    -e 's/$(PRODUCT_BUNDLE_IDENTIFIER)/dev.solderable.ddpm.S2725QC/' \
    -e 's/${PRODUCT_NAME}/S2725QC/' \
    -e 's/$(MARKETING_VERSION)/0.7.2/' \
    -e 's/e395c745-4eea-4d94-bb92-46224221047c/C6241744-431F-457A-9C33-D659840B7E56/g' \
    ../vendor/BlackHole/BlackHole/BlackHole.plist > "$OUT/Contents/Info.plist"
codesign --force --sign - "$OUT"
echo "built $OUT"
