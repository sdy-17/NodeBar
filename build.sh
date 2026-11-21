#!/bin/bash
set -eu
cd "$(dirname "$0")"
app="$PWD/build/NodeBar.app"
mkdir -p "$app/Contents/MacOS"
export CLANG_MODULE_CACHE_PATH="$PWD/build/module-cache"
swiftc -swift-version 5 -O -import-objc-header Sources/ProcessInfo.h Sources/*.swift -o "$app/Contents/MacOS/NodeBar"
cp Info.plist "$app/Contents/Info.plist"
codesign --force --sign - "$app"
