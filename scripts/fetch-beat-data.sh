#!/usr/bin/env bash
# Готовит данные для wave-eval на Linux: GTZAN (аудио и разметка долей) в ~/datasets/wavefeels.
# Использование: scripts/fetch-beat-data.sh [ПАПКА]   (по умолчанию ~/datasets/wavefeels или $WAVEFEELS_DATA)
#
#   1. raw/genres.tar.gz: скачивается, если нет, и распаковывается, если raw/genres неполон;
#   2. raw/ann: клон https://github.com/TempoBeatDownbeat/gtzan_tempo_beat, если его нет;
#   3. gtzan48k/<жанр>.000NN.wav: ffmpeg в 48 кГц, моно, 32 бит float, уже готовые файлы пропускаются;
#   4. gtzan.tsv: <wav>\t<разметка>\t<жанр>\t<tune|heldout>, каждый пятый файл жанра
#      (номер NN % 5 == 4) отложенный. Файлы без разметки пропускаются и перечисляются в
#      gtzan.skipped.txt и на stderr.
#
# Идемпотентен: повторный запуск ничего не скачивает и не конвертирует заново. Данные считаются
# недоверенными: из них ничего не запускается (разметка берется по закрепленному коммиту без
# хуков, архив проверяется по sha256 и на символические ссылки, ffmpeg читает только file:), в репозиторий ничего не пишется. Нужны bash, curl, git, tar, ffmpeg.
set -euo pipefail

ROOT="${1:-${WAVEFEELS_DATA:-$HOME/datasets/wavefeels}}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO="$(cd "$HERE/.." && pwd -P)"

mkdir -p "$ROOT"
ROOT="$(cd "$ROOT" && pwd -P)"
case "$ROOT/" in
    "$REPO"/*) echo "fetch-beat-data: $ROOT лежит внутри репозитория, данные пишутся только вне его" >&2; exit 1 ;;
esac

GENRES=(blues classical country disco hiphop jazz metal pop reggae rock)
AUDIO_URL="https://huggingface.co/datasets/marsyas/gtzan/resolve/main/data/genres.tar.gz"
ANN_URL="https://github.com/TempoBeatDownbeat/gtzan_tempo_beat"
# Версии данных закреплены, чтобы базовые числа воспроизводились.
ANN_COMMIT="fd9cafdebb6426fee41c3718791be61306323dd7"
AUDIO_SHA256="b28cc067ff6199bd826f5d1a6931458586d64acae7f44b2e882b7a97af057531"
RAW="$ROOT/raw"
OUT="$ROOT/gtzan48k"
mkdir -p "$RAW" "$OUT"

for tool in ffmpeg curl git tar; do
    command -v "$tool" >/dev/null || { echo "fetch-beat-data: нужен $tool" >&2; exit 1; }
done

# Сколько настоящих wav лежит в raw/genres (файлы ресурсов macOS ._* не считаются).
count_raw() {
    find "$RAW/genres" -type f -name '*.wav' ! -name '._*' 2>/dev/null | wc -l
}

if [ "$(count_raw)" -lt 1000 ]; then
    if [ ! -s "$RAW/genres.tar.gz" ]; then
        echo "fetch-beat-data: скачиваю аудио GTZAN"
        curl -fL --retry 3 -o "$RAW/genres.tar.gz.part" "$AUDIO_URL"
        mv "$RAW/genres.tar.gz.part" "$RAW/genres.tar.gz"
    fi
    actual="$(sha256sum "$RAW/genres.tar.gz" | cut -d' ' -f1)"
    [ "$actual" = "$AUDIO_SHA256" ] || { echo "fetch-beat-data: контрольная сумма genres.tar.gz $actual, ожидалась $AUDIO_SHA256" >&2; exit 1; }
    echo "fetch-beat-data: распаковываю аудио"
    # GNU tar сам отбрасывает ведущий / и члены с "..". Ошибки показываются; шум про расширенные заголовки macOS убирается.
    tar -xzf "$RAW/genres.tar.gz" -C "$RAW" --no-same-owner --exclude='._*' --exclude='.DS_Store' \
        2> >(grep -v 'unknown extended header keyword' >&2)
    if [ -n "$(find "$RAW/genres" -type l -print -quit)" ]; then
        echo "fetch-beat-data: в архиве есть символические ссылки, стоп" >&2
        exit 1
    fi
    [ "$(count_raw)" -ge 1000 ] || { echo "fetch-beat-data: в архиве меньше 1000 wav" >&2; exit 1; }
fi

if [ ! -d "$RAW/ann/beats" ]; then
    echo "fetch-beat-data: клонирую разметку долей"
    rm -rf "$RAW/ann" "$RAW/ann.part"
    git init -q "$RAW/ann.part"
    git -C "$RAW/ann.part" fetch -q --depth 1 "$ANN_URL" "$ANN_COMMIT"
    git -C "$RAW/ann.part" -c advice.detachedHead=false checkout -q FETCH_HEAD
    mv "$RAW/ann.part" "$RAW/ann"
fi
if [ "$(git -C "$RAW/ann" rev-parse HEAD 2>/dev/null)" != "$ANN_COMMIT" ]; then
    echo "fetch-beat-data: предупреждение: разметка не на закрепленной версии $ANN_COMMIT" >&2
fi

# Конвертация: один файл на вызов, запись через временный файл, чтобы обрыв не оставил полфайла.
convert_one() {
    local in="$1" out="$2"
    [ -s "$out" ] && return 0
    # Битый файл (в GTZAN известен jazz.00054) не должен ронять остальные: он попадет в список пропущенных.
    if ffmpeg -nostdin -loglevel error -y -protocol_whitelist file -i "$in" -ac 1 -ar 48000 -c:a pcm_f32le -f wav "$out.part"; then
        mv "$out.part" "$out"
    else
        rm -f "$out.part"
        echo "fetch-beat-data: не удалось конвертировать $in" >&2
    fi
    return 0
}
export -f convert_one

JOBS="$(nproc 2>/dev/null || echo 4)"
# shellcheck disable=SC2016
for genre in "${GENRES[@]}"; do
    find "$RAW/genres/$genre" -maxdepth 1 -type f -name '*.wav' ! -name '._*' -print0 | sort -z |
        while IFS= read -r -d '' wav; do
            printf '%s\0%s\0' "$wav" "$OUT/$(basename "$wav")"
        done
done | xargs -0 -n 2 -P "$JOBS" bash -c 'convert_one "$1" "$2"' _
rm -f "$OUT"/*.part

TSV="$ROOT/gtzan.tsv"
SKIPPED="$ROOT/gtzan.skipped.txt"
: >"$SKIPPED.new"
: >"$TSV.new"
total=0
for genre in "${GENRES[@]}"; do
    for raw in "$RAW/genres/$genre/$genre".*.wav; do
        [ -e "$raw" ] || continue
        base="$(basename "$raw" .wav)"      # blues.00012
        num="${base##*.}"                   # 00012
        wav="$OUT/$base.wav"
        ann="$RAW/ann/beats/gtzan_${genre}_${num}.beats"
        if [ ! -s "$wav" ]; then
            echo "$base без аудио" >>"$SKIPPED.new"
            echo "fetch-beat-data: нет сконвертированного аудио для $base, пропущен" >&2
            continue
        fi
        if [ ! -s "$ann" ]; then
            echo "$base без разметки" >>"$SKIPPED.new"
            echo "fetch-beat-data: нет разметки для $base, пропущен" >&2
            continue
        fi
        split=tune
        if [ $((10#$num % 5)) -eq 4 ]; then split=heldout; fi
        printf '%s\t%s\t%s\t%s\n' "$wav" "$ann" "$genre" "$split" >>"$TSV.new"
        total=$((total + 1))
    done
done
mv "$TSV.new" "$TSV"
mv "$SKIPPED.new" "$SKIPPED"
echo "fetch-beat-data: $total файлов в $TSV, пропущено $(wc -l <"$SKIPPED")"
