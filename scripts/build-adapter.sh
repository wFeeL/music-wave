#!/usr/bin/env bash
# Собирает ungive/mediaremote-adapter из исходников на коммите из Vendor/mediaremote-adapter.commit
# и кладет части для бандла в dist/adapter/:
#   mediaremote-adapter.pl, MediaRemoteAdapter.framework, MediaRemoteAdapterTestClient, LICENSE.
# bundle.sh раскладывает их по Contents/Resources/Adapter, Contents/Frameworks, Contents/Helpers.
# Исходники клонируются в .build/adapter-src. Сборка (cmake) работает только на macOS.
# Скрипт рассчитан на bash 3.2 и BSD-утилиты.
set -euo pipefail

cd "$(dirname "$0")/.."

REPO=https://github.com/ungive/mediaremote-adapter
COMMIT=$(tr -d '[:space:]' < Vendor/mediaremote-adapter.commit)
SRC=.build/adapter-src
OUT=dist/adapter

if ! [[ "$COMMIT" =~ ^[0-9a-f]{40}$ ]]; then
    echo "error: Vendor/mediaremote-adapter.commit must hold a full commit hash, got '$COMMIT'" >&2
    exit 1
fi

# Старые части не должны попасть в бандл, если сборка ниже упадет.
rm -rf "$OUT"

if [[ ! -d "$SRC/.git" ]]; then
    rm -rf "$SRC"
    mkdir -p "$(dirname "$SRC")"
    git clone --quiet "$REPO" "$SRC"
fi
if ! git -C "$SRC" cat-file -e "$COMMIT^{commit}" 2>/dev/null; then
    git -C "$SRC" fetch --quiet origin
fi
git -C "$SRC" checkout --quiet --force --detach "$COMMIT"
echo "mediaremote-adapter at $(git -C "$SRC" rev-parse HEAD)"

if ! command -v cmake > /dev/null; then
    echo "error: cmake not found (the adapter builds only on macOS with cmake)" >&2
    exit 1
fi

# CMakeLists адаптера сам задает универсальную сборку (x86_64 и arm64) и ad-hoc подпись
# фреймворка; sign.sh потом переподписывает все с --force.
(
    cd "$SRC"
    cmake -S . -B build -DCMAKE_BUILD_TYPE=Release
    cmake --build build
)

mkdir -p "$OUT"
cp "$SRC/bin/mediaremote-adapter.pl" "$OUT/mediaremote-adapter.pl"
# ditto сохраняет символические ссылки внутри фреймворка.
ditto "$SRC/build/MediaRemoteAdapter.framework" "$OUT/MediaRemoteAdapter.framework"
cp "$SRC/build/MediaRemoteAdapterTestClient" "$OUT/MediaRemoteAdapterTestClient"
cp "$SRC/LICENSE" "$OUT/LICENSE"

lipo -info "$OUT/MediaRemoteAdapter.framework/MediaRemoteAdapter" "$OUT/MediaRemoteAdapterTestClient"
echo "adapter ready in $OUT"
find "$OUT" -print | sort
