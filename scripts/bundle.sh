#!/usr/bin/env bash
# Собирает dist/WaveFeels.app из release-бинарника SwiftPM.
# Использование: scripts/bundle.sh <version> <build> [<output.app>], например 1.2.3 42.
# Третий аргумент задает путь к собираемому .app (по умолчанию dist/WaveFeels.app,
# относительный путь считается от корня репозитория).
# Перед запуском нужен `swift build -c release`.
# Необязательные части адаптера берутся из $ADAPTER_DIR (по умолчанию dist/adapter, туда их
# кладет build-adapter.sh), если собраны.
# Иконка: Resources/AppIcon.icns, если она есть, иначе scripts/make-icon.swift рисует в
# dist/icon (повторно только после правки скрипта) AppIcon.icns и пакет AppIcon.icon для
# macOS 26. Пакет собирает `xcrun actool` в Assets.car, тогда в Info.plist добавляется
# CFBundleIconName; не собрался, приложение остается с одним .icns (CFBundleIconFile).
# С $ICON_SNAPSHOT_DIR туда кладутся icon.png (1024 px), icon-sizes.png (все размеры) и,
# если Icon Composer на месте, icon-macos26.png (как .icon рисует система) и варианты
# icon-macos26-dark.png, -clear.png, -tinted.png.
# С $RELEASE без AppIcon.icns сборка падает.
# В Info.plist пишутся WFCommit (короткий хэш: $WF_COMMIT, иначе git с -dirty при правках,
# иначе хэш из архива GitHub, иначе unknown) и
# WFSwiftVersion (из swift --version), их показывает «Диагностика», строка «Сборка».
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

# Коммит сборки для «Диагностики»: $WF_COMMIT, иначе короткий хэш из git (только если корень
# репозитория свой, а не чужой, внутри которого распакован архив), иначе хэш, который git archive
# подставил в scripts/archive-commit.txt (архив GitHub, см. .gitattributes), иначе unknown.
COMMIT=${WF_COMMIT:-}
if [[ -z "$COMMIT" && -e .git ]] && command -v git > /dev/null 2>&1; then
    COMMIT=$(git rev-parse --short HEAD 2> /dev/null || true)
    # Правки в отслеживаемых файлах: сборка не совпадает с коммитом.
    if [[ -n "$COMMIT" ]] && ! git diff --quiet HEAD -- 2> /dev/null; then
        COMMIT="$COMMIT-dirty"
    fi
fi
if [[ -z "$COMMIT" && -f scripts/archive-commit.txt ]]; then
    ARCHIVED=$(head -n 1 scripts/archive-commit.txt | tr -d '[:space:]')
    if [[ "$ARCHIVED" =~ ^[0-9a-f]{7,40}$ ]]; then
        COMMIT=$ARCHIVED
    fi
fi
COMMIT=${COMMIT:-unknown}
# Версия компилятора: число после "Swift version" в swift --version (первая строка может быть
# версией swift-driver).
SWIFT_VERSION=$({ swift --version 2>&1 || true; } |
    sed -nE 's/.*Swift version ([0-9]+(\.[0-9]+)*).*/\1/p' | head -n 1) || SWIFT_VERSION=""
SWIFT_VERSION=${SWIFT_VERSION:-unknown}
plutil -replace WFCommit -string "$COMMIT" "$CONTENTS/Info.plist"
plutil -replace WFSwiftVersion -string "$SWIFT_VERSION" "$CONTENTS/Info.plist"
plutil -lint "$CONTENTS/Info.plist"

# Рисует иконку в каталог $1. В `if !` set -e не действует, поэтому шаги связаны через &&.
make_icon() {
    rm -rf "$1" && mkdir -p "$1" &&
        swift scripts/make-icon.swift "$1/AppIcon.iconset" "$1/icon-sizes.png" "$1/AppIcon.icon" &&
        iconutil -c icns -o "$1/AppIcon.icns" "$1/AppIcon.iconset"
}

# Собирает $1/AppIcon.icon в $1/car/Assets.car и рисует превью icon-macos26.png через ictool
# из Icon Composer. actool возвращает 0 и при ошибке, поэтому успех определяется по Assets.car.
# Пути абсолютные: относительные actool ищет не там.
compile_icon() {
    local dir="$PWD/$1" ictool
    rm -rf "$dir/car" && mkdir -p "$dir/car" || return 1
    xcrun actool "$dir/AppIcon.icon" --compile "$dir/car" \
        --output-format human-readable-text --notices --warnings --errors \
        --output-partial-info-plist "$dir/car/partial.plist" \
        --app-icon AppIcon --include-all-app-icons --enable-on-demand-resources NO \
        --development-region en --target-device mac --minimum-deployment-target 26.0 \
        --platform macosx || true
    [[ -f "$dir/car/Assets.car" ]] || return 1
    xcrun assetutil --info "$dir/car/Assets.car" || true
    ictool="${DEVELOPER_DIR:-$(xcode-select -p)}/../Applications/Icon Composer.app/Contents/Executables/ictool"
    if [[ -x "$ictool" ]]; then
        # Справка в лог: по ней видно, какие варианты (renditions) знает эта версия ictool.
        "$ictool" --help || true
        local variant rendition suffix
        for variant in Default: Dark:-dark ClearLight:-clear TintedLight:-tinted; do
            rendition=${variant%%:*}
            suffix=${variant#*:}
            "$ictool" "$dir/AppIcon.icon" --export-image --output-file "$dir/icon-macos26$suffix.png" \
                --platform macOS --rendition "$rendition" --width 1024 --height 1024 --scale 1 ||
                echo "warning: ictool could not render AppIcon.icon ($rendition)" >&2
        done
    fi
    return 0
}

CAR=""
if [[ -f Resources/AppIcon.icns ]]; then
    ICNS=Resources/AppIcon.icns
else
    ICON_DIR=dist/icon
    ICNS="$ICON_DIR/AppIcon.icns"
    # .icns пишется последним: если его нет, прошлый запуск не дошел до конца.
    if [[ ! -f "$ICNS" || scripts/make-icon.swift -nt "$ICNS" ]] && ! make_icon "$ICON_DIR"; then
        if [[ -n "${RELEASE:-}" ]]; then
            echo "error: icon generation failed, a release needs AppIcon.icns" >&2
            exit 1
        fi
        # Без иконки бандл все равно собирается, чтобы подпись и снимки прошли; пропажу
        # icon.png заметит проверка снимков в ci-mac.sh.
        echo "warning: icon generation failed, bundling without icon" >&2
        rm -f "$ICNS"
    fi
    if [[ -f "$ICNS" && -d "$ICON_DIR/AppIcon.icon" ]]; then
        if [[ -f "$ICON_DIR/car/Assets.car" ]] || compile_icon "$ICON_DIR"; then
            CAR="$ICON_DIR/car/Assets.car"
        else
            echo "warning: actool could not compile AppIcon.icon, bundling AppIcon.icns only" >&2
        fi
    fi
    if [[ -n "${ICON_SNAPSHOT_DIR:-}" && -f "$ICNS" ]]; then
        mkdir -p "$ICON_SNAPSHOT_DIR"
        cp "$ICON_DIR/AppIcon.iconset/icon_512x512@2x.png" "$ICON_SNAPSHOT_DIR/icon.png"
        cp "$ICON_DIR/icon-sizes.png" "$ICON_SNAPSHOT_DIR/icon-sizes.png"
        for preview in "$ICON_DIR"/icon-macos26*.png; do
            if [[ -f "$preview" ]]; then
                cp "$preview" "$ICON_SNAPSHOT_DIR/"
            fi
        done
    fi
fi
if [[ -f "$ICNS" ]]; then
    cp "$ICNS" "$CONTENTS/Resources/AppIcon.icns"
fi
if [[ -n "$CAR" ]]; then
    cp "$CAR" "$CONTENTS/Resources/Assets.car"
    plutil -replace CFBundleIconName -string AppIcon "$CONTENTS/Info.plist"
fi
if [[ -n "${RELEASE:-}" && ! -f "$CONTENTS/Resources/AppIcon.icns" ]]; then
    echo "error: $CONTENTS/Resources/AppIcon.icns missing, a release needs it" >&2
    exit 1
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

echo "bundled $APP (version $VERSION, build $BUILD, commit $COMMIT, Swift $SWIFT_VERSION)"
find "$APP" -print | sort
