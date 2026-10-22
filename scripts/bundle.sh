#!/usr/bin/env bash
# Собирает dist/WaveFeels.app из release-бинарника SwiftPM.
# Использование: scripts/bundle.sh <version> <build> [<output.app>], например 1.2.3 42.
# Третий аргумент задает путь к собираемому .app (по умолчанию dist/WaveFeels.app,
# относительный путь считается от корня репозитория).
# Перед запуском нужен `swift build -c release`.
# Необязательные части адаптера берутся из $ADAPTER_DIR (по умолчанию dist/adapter, туда их
# кладет build-adapter.sh), если собраны.
# Иконка: Resources/AppIcon.icns, если она есть, иначе scripts/make-icon.swift рисует ее в
# dist/icon (повторно только после правки скрипта). С $ICON_SNAPSHOT_DIR туда же кладутся
# icon.png (1024 px) и icon-sizes.png (все размеры) для проверки на глаз.
set -euo pipefail

cd "$(dirname "$0")/.."

if [[ $# -lt 2 || $# -gt 3 ]]; then
    echo "usage: $0 <version> <build> [<output.app>]" >&2
    exit 2
fi
VERSION=$1
BUILD=$2
APP=${3:-dist/WaveFeels.app}

if [[ "$APP" != *.app ]]; then
    echo "error: output path must end with .app, got '$APP'" >&2
    exit 2
fi

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
CONTENTS="$APP/Contents"

rm -rf "$APP"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources/Demo"

cp "$BINARY" "$CONTENTS/MacOS/WaveFeels"

cp Resources/Info.plist "$CONTENTS/Info.plist"
plutil -replace CFBundleShortVersionString -string "$VERSION" "$CONTENTS/Info.plist"
plutil -replace CFBundleVersion -string "$BUILD" "$CONTENTS/Info.plist"
plutil -lint "$CONTENTS/Info.plist"

# Рисует иконку в каталог $1. В `if !` set -e не действует, поэтому шаги связаны через &&.
make_icon() {
    rm -rf "$1" && mkdir -p "$1" &&
        swift scripts/make-icon.swift "$1/AppIcon.iconset" "$1/icon-sizes.png" &&
        iconutil -c icns -o "$1/AppIcon.icns" "$1/AppIcon.iconset"
}

if [[ -f Resources/AppIcon.icns ]]; then
    ICNS=Resources/AppIcon.icns
else
    ICON_DIR=dist/icon
    ICNS="$ICON_DIR/AppIcon.icns"
    # .icns пишется последним: если его нет, прошлый запуск не дошел до конца.
    if [[ ! -f "$ICNS" || scripts/make-icon.swift -nt "$ICNS" ]] && ! make_icon "$ICON_DIR"; then
        # Без иконки бандл все равно собирается, чтобы подпись и снимки прошли; пропажу
        # icon.png заметит проверка снимков в ci-mac.sh.
        echo "warning: icon generation failed, bundling without icon" >&2
        rm -f "$ICNS"
    fi
    if [[ -n "${ICON_SNAPSHOT_DIR:-}" ]]; then
        mkdir -p "$ICON_SNAPSHOT_DIR"
        if [[ -f "$ICON_DIR/AppIcon.iconset/icon_512x512@2x.png" ]]; then
            cp "$ICON_DIR/AppIcon.iconset/icon_512x512@2x.png" "$ICON_SNAPSHOT_DIR/icon.png"
        fi
        if [[ -f "$ICON_DIR/icon-sizes.png" ]]; then
            cp "$ICON_DIR/icon-sizes.png" "$ICON_SNAPSHOT_DIR/icon-sizes.png"
        fi
    fi
fi
if [[ -f "$ICNS" ]]; then
    cp "$ICNS" "$CONTENTS/Resources/AppIcon.icns"
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
