#!/usr/bin/env bash
# Собирает dist/WaveFeels.app из release-бинарника SwiftPM.
# Использование: scripts/bundle.sh <version> <build>, например 1.2.3 42.
# Перед запуском нужен `swift build -c release`.
# Необязательные части адаптера берутся из $ADAPTER_DIR (по умолчанию dist/adapter, туда их
# кладет build-adapter.sh), если собраны.
set -euo pipefail

cd "$(dirname "$0")/.."

if [[ $# -ne 2 ]]; then
    echo "usage: $0 <version> <build>" >&2
    exit 2
fi
VERSION=$1
BUILD=$2

if ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "error: version must look like 1.2.3, got '$VERSION'" >&2
    exit 2
fi
if ! [[ "$BUILD" =~ ^[0-9]+$ ]]; then
    echo "error: build must be a number, got '$BUILD'" >&2
    exit 2
fi

BIN_DIR=$(swift build -c release --show-bin-path)
BINARY="$BIN_DIR/WaveFeels"
if [[ ! -x "$BINARY" ]]; then
    echo "error: $BINARY not found, run 'swift build -c release' first" >&2
    exit 1
fi

ADAPTER_DIR=${ADAPTER_DIR:-dist/adapter}
APP=dist/WaveFeels.app
CONTENTS="$APP/Contents"

rm -rf "$APP"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources/Demo"

cp "$BINARY" "$CONTENTS/MacOS/WaveFeels"

cp Resources/Info.plist "$CONTENTS/Info.plist"
plutil -replace CFBundleShortVersionString -string "$VERSION" "$CONTENTS/Info.plist"
plutil -replace CFBundleVersion -string "$BUILD" "$CONTENTS/Info.plist"
plutil -lint "$CONTENTS/Info.plist"

if [[ -f Resources/AppIcon.icns ]]; then
    cp Resources/AppIcon.icns "$CONTENTS/Resources/AppIcon.icns"
fi

cp Resources/Demo/demo.wav Resources/Demo/silence.wav "$CONTENTS/Resources/Demo/"

if [[ -d Resources/LICENSES ]]; then
    ditto Resources/LICENSES "$CONTENTS/Resources/LICENSES"
fi

if [[ -f "$ADAPTER_DIR/mediaremote-adapter.pl" ]]; then
    mkdir -p "$CONTENTS/Resources/Adapter"
    cp "$ADAPTER_DIR/mediaremote-adapter.pl" "$CONTENTS/Resources/Adapter/mediaremote-adapter.pl"
fi
if [[ -f "$ADAPTER_DIR/LICENSE" ]]; then
    mkdir -p "$CONTENTS/Resources/LICENSES"
    cp "$ADAPTER_DIR/LICENSE" "$CONTENTS/Resources/LICENSES/mediaremote-adapter.txt"
fi
if [[ -d "$ADAPTER_DIR/MediaRemoteAdapter.framework" ]]; then
    mkdir -p "$CONTENTS/Frameworks"
    # ditto сохраняет символические ссылки внутри фреймворка.
    ditto "$ADAPTER_DIR/MediaRemoteAdapter.framework" "$CONTENTS/Frameworks/MediaRemoteAdapter.framework"
fi
if [[ -f "$ADAPTER_DIR/MediaRemoteAdapterTestClient" ]]; then
    mkdir -p "$CONTENTS/Helpers"
    cp "$ADAPTER_DIR/MediaRemoteAdapterTestClient" "$CONTENTS/Helpers/MediaRemoteAdapterTestClient"
fi

echo "bundled $APP (version $VERSION, build $BUILD)"
find "$APP" -print | sort
