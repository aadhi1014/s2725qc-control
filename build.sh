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
echo "build complete"
