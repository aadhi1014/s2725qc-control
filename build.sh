#!/bin/zsh
# Builds the ddc CLI, the S2725QC Control agent app, and the virtual audio driver.
set -e
cd "$(dirname "$0")"
mkdir -p build

swiftc -O Sources/Shared/*.swift Sources/CLI/*.swift -o build/ddc

clang -O2 -c Sources/ShmRing/ddpm_reader.c -o build/ddpm_reader.o
swiftc -O -emit-library -module-name S2725QCAgent -import-objc-header Sources/ShmRing/ddpm_reader.h \
  Sources/Shared/*.swift Sources/Agent/*.swift build/ddpm_reader.o -o build/libS2725QCAgent.dylib
codesign --force --sign - build/libS2725QCAgent.dylib

# The app is only a launcher for the library above. It is built once and left alone so its
# signature (and the Accessibility permission tied to it) survives rebuilds; pass --launcher to rebuild it.
APP="build/S2725QC Control.app"
if [[ ! -d "$APP" || "$1" == "--launcher" ]]; then
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
swiftc -O Sources/Launcher/main.swift -o "$APP/Contents/MacOS/S2725QCControl"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>dev.solderable.s2725qc-control</string>
  <key>CFBundleName</key><string>S2725QC Control</string>
  <key>CFBundleExecutable</key><string>S2725QCControl</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST
codesign --force --sign - "$APP"
fi

driver/build.sh

# Speaker setup app (layout, test tones, microphone calibration). A normal app that runs only
# while its window is open; its own bundle so the microphone permission belongs to it alone.
SETUP="build/S2725QC Setup.app"
rm -rf "$SETUP"
mkdir -p "$SETUP/Contents/MacOS" "$SETUP/Contents/Resources"
swiftc -O -parse-as-library Sources/Setup/*.swift -o "$SETUP/Contents/MacOS/S2725QCSetup"
# Icon: drawn by Resources/make-icon.swift (swift make-icon.swift out.png, then iconutil).
cp Resources/SetupIcon.icns "$SETUP/Contents/Resources/"
# The driver ships inside the app so it can install and update it.
cp -R driver/build/S2725QC.driver "$SETUP/Contents/Resources/"
cat > "$SETUP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>dev.solderable.s2725qc-setup</string>
  <key>CFBundleName</key><string>S2725QC Setup</string>
  <key>CFBundleDisplayName</key><string>S2725QC Speaker Setup</string>
  <key>CFBundleExecutable</key><string>S2725QCSetup</string>
  <key>CFBundleIconFile</key><string>SetupIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSMicrophoneUsageDescription</key><string>Measures when each monitor speaker's sound reaches you, to line them up.</string>
</dict>
</plist>
PLIST
codesign --force --sign - "$SETUP"

echo "build complete"
