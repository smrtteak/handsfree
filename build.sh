#!/bin/zsh
# Runs the gesture tests, then builds build/Handsfree.app.
set -euo pipefail
cd "$(dirname "$0")"

TARGET=arm64-apple-macos13.0
FLAGS=(-swift-version 5 -target "$TARGET")
APP=build/Handsfree.app
mkdir -p build

swiftc "${FLAGS[@]}" Sources/Core/GestureCore.swift Tests/main.swift -o build/gesture-tests
build/gesture-tests

mkdir -p "$APP/Contents/MacOS"
swiftc -O "${FLAGS[@]}" Sources/Core/GestureCore.swift Sources/App/main.swift -o "$APP/Contents/MacOS/Handsfree"
cp Info.plist "$APP/Contents/Info.plist"
# A stable certificate keeps the Accessibility grant across rebuilds; ad-hoc signing loses it.
IDENTITY=$(security find-certificate -c "Handsfree Local Signing" -Z 2>/dev/null | awk '/SHA-1/{print $NF}')
codesign --force --sign "${IDENTITY:--}" "$APP"
echo "Built $APP"
