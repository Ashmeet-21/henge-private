#!/bin/bash
# Select Xcode 27.3+ with DEVELOPER_DIR. This does not need the external iOS build dependencies.
set -euo pipefail
cd "$(dirname "$0")/.."
make test-native-touch build/henge-agent.gz build/henge-touch-agent.gz build/share.o build/native_touch.o
xcrun --sdk macosx swiftc -swift-version 6 -strict-concurrency=complete -warnings-as-errors \
    -parse-as-library -typecheck tools/henge-touch-agent.swift tools/native-touch/*.swift
sdk="$(xcrun --sdk iphonesimulator --show-sdk-path)"
sources=()
while IFS= read -r -d '' source; do sources+=("$source"); done < <(find ios/Henge -name '*.swift' -print0)
xcrun --sdk iphonesimulator swiftc -typecheck -target arm64-apple-ios17.0-simulator -sdk "$sdk" \
    -import-objc-header ios/Henge/HengeBridge.h -Ihost -Idevices -Icore \
    "${sources[@]}" ios/HengeJITHelper/HengeJITMessages.swift
for source in native_touch share; do
    xcrun --sdk iphoneos clang -arch arm64 -miphoneos-version-min=17.0 -Wall -Wextra -Werror \
        -Ihost -c "host/$source.c" -o "build/${source}_ios.o"
done
