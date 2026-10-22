#!/usr/bin/env bash
# Все шаги mac-сборки в одном месте. Использование: scripts/ci-mac.sh <fast|snap|full>
#   fast: swift build --build-tests, swift test --skip-build
#   snap: swift build -c release, bundle.sh, sign.sh, снимки и пробный запуск из бандла
#   full: адаптер, release-сборка, тесты, бандл, подпись, снимки, пробный запуск, замер CPU, zip
# С RELEASE=1 (release.yml) режим full дополнительно собирает вторую копию для проверки обновления:
# тот же бинарник, CFBundleVersion "<номер запуска>1", dist/update-test/WaveFeels.app, подпись и
# архив dist/WaveFeels-<тег>-update-test.zip. Designated requirement обеих копий пишется в sign.txt.
# Результаты в ci-out/: summary.md, errors.txt, build.log, test.log, sign.txt, snapshots/, cpu.txt.
# Каждый шаг идет под своим лимитом времени (в macOS нет timeout, работает фоновый сторож).
# Шаги из будущих задач (--render-snapshots, cpu-probe.sh) пропускаются, пока их нет,
# с отметкой skipped в summary.md. Адаптер (build-adapter.sh) собирается только в режиме full,
# в остальных режимах бандл идет без него.
# Скрипт рассчитан на bash 3.2 и BSD-утилиты.
set -uo pipefail

MODE=${1:-fast}
case "$MODE" in
    fast | snap | full) ;;
    *)
        echo "usage: $0 <fast|snap|full>" >&2
        exit 2
        ;;
esac

cd "$(dirname "$0")/.." || exit 1
ROOT=$PWD
OUT="$ROOT/ci-out"
export OUT
rm -rf "$OUT"
mkdir -p "$OUT/snapshots"

SUMMARY="$OUT/summary.md"
STEPS="$OUT/.steps.md"
: > "$STEPS"
START=$SECONDS
FAILED=0

REF=${GITHUB_REF_NAME:-local}
REF_SAFE=$(printf '%s' "$REF" | tr -c 'A-Za-z0-9._-' '-')
SHA=${GITHUB_SHA:-$(git rev-parse HEAD 2>/dev/null || echo unknown)}
RUN_NUMBER=${GITHUB_RUN_NUMBER:-0}
if [[ "$REF" =~ ^v([0-9]+\.[0-9]+\.[0-9]+)(-.+)?$ ]]; then
    VERSION=${BASH_REMATCH[1]}
else
    VERSION="0.0.$RUN_NUMBER"
fi
BUILD=$RUN_NUMBER

APP="$ROOT/dist/WaveFeels.app"
UPDATE_APP="$ROOT/dist/update-test/WaveFeels.app"
UPDATE_BUILD="${BUILD}1"
APP_LOG="$HOME/Library/Logs/WaveFeels/wavefeels.log"

# Лимиты шагов, секунды.
LIMIT_BUILD=360
LIMIT_TEST=240
LIMIT_SNAPSHOTS=120
LIMIT_CPU=180
LIMIT_SIGN=120
LIMIT_SMALL=120

# --- служебные функции ---

record() { # шаг, исход, секунды, примечание
    printf '| %s | %s | %s | %s |\n' "$1" "$2" "$3" "${4:-}" >> "$STEPS"
    echo "== step $1: $2 (${3}s) ${4:-}"
}

skip() { # шаг, причина
    record "$1" skipped - "$2"
}

descendants() { # pid: печатает всех потомков процесса
    local child
    for child in $(pgrep -P "$1" 2>/dev/null); do
        echo "$child"
        descendants "$child"
    done
}

any_alive() { # pid...
    local p
    for p in "$@"; do
        if kill -0 "$p" 2>/dev/null; then
            return 0
        fi
    done
    return 1
}

watchdog() { # pid, лимит, файл-отметка, лог
    local deadline=$((SECONDS + $2)) tree grace=0
    while kill -0 "$1" 2>/dev/null; do
        if [[ $SECONDS -ge $deadline ]]; then
            echo "watchdog: step exceeded $2 s, terminating" >> "$4"
            : > "$3"
            # Дерево собирается до TERM: после смерти родителя потомки уходят к launchd.
            tree="$1 $(descendants "$1" | tr '\n' ' ')"
            # shellcheck disable=SC2086 # список pid нужно разбить на отдельные аргументы
            kill -TERM $tree 2>/dev/null
            # shellcheck disable=SC2086 # то же
            while [[ $grace -lt 10 ]] && any_alive $tree; do
                sleep 1
                grace=$((grace + 1))
            done
            # shellcheck disable=SC2086 # то же
            kill -KILL $tree 2>/dev/null
            return 0
        fi
        sleep 1
    done
}

run_step() { # имя, лимит, лог, команда...
    local name=$1 limit=$2 log=$3
    shift 3
    local marker="$OUT/.timeout-$name" t0=$SECONDS pid wd rc dt
    echo "== step $name: $*" >> "$log"
    "$@" >> "$log" 2>&1 &
    pid=$!
    watchdog "$pid" "$limit" "$marker" "$log" > /dev/null 2>&1 &
    wd=$!
    wait "$pid"
    rc=$?
    if [[ -f "$marker" ]]; then
        # Сторож уже сработал: ждем, пока он добьет выживших потомков через KILL.
        wait "$wd" 2>/dev/null
    else
        kill "$wd" 2>/dev/null
        wait "$wd" 2>/dev/null
    fi
    dt=$((SECONDS - t0))
    if [[ -f "$marker" ]]; then
        record "$name" timeout "$dt" "limit ${limit}s"
        rc=124
    elif [[ $rc -eq 0 ]]; then
        record "$name" success "$dt"
    else
        record "$name" failure "$dt" "exit $rc"
    fi
    if [[ $rc -ne 0 ]]; then
        FAILED=1
    fi
    return "$rc"
}

toolchain_info() {
    swift --version
    xcodebuild -version
}

smoke_launch() {
    # Лог удаляется только на CI, чтобы не стереть настоящий лог разработчика.
    if [[ -n "${CI:-}" ]]; then
        rm -f "$APP_LOG"
    fi
    "$APP/Contents/MacOS/WaveFeels" --exit-after 3 --no-capture
}

render_snapshots() {
    "$APP/Contents/MacOS/WaveFeels" --render-snapshots "$OUT/snapshots" \
        --demo "$APP/Contents/Resources/Demo/demo.wav" --fake-notch --no-capture
}

has_snapshot_renderer() {
    [[ -f Sources/WaveFeels/Snapshots/SnapshotRenderer.swift ]]
}

write_errors() {
    {
        if [[ -f "$OUT/build.log" ]]; then
            grep -E ': (error|warning):' "$OUT/build.log" | sort -u
        fi
        if [[ -f "$OUT/test.log" ]]; then
            grep -E ': (error|warning):|✘' "$OUT/test.log"
        fi
    } > "$OUT/errors.txt" 2>/dev/null || true
}

finish() {
    local result=success
    if [[ $FAILED -ne 0 ]]; then
        result=failure
    fi
    write_errors
    {
        echo "# WaveFeels mac CI: $MODE"
        echo
        echo "- result: $result"
        echo "- ref: $REF"
        echo "- sha: $SHA"
        echo "- run: ${GITHUB_RUN_NUMBER:-local} attempt ${GITHUB_RUN_ATTEMPT:-1}"
        echo "- app version: $VERSION (build $BUILD)"
        echo "- duration: $((SECONDS - START)) s"
        echo
        echo "## Steps"
        echo
        echo "| step | outcome | seconds | note |"
        echo "|---|---|---|---|"
        cat "$STEPS"
        echo
        echo "## Toolchain"
        echo
        echo '```'
        if [[ -f "$OUT/toolchain.txt" ]]; then
            grep -v '^== step' "$OUT/toolchain.txt"
        fi
        echo '```'
        echo
        echo "## Errors and warnings (first 40, full list in errors.txt)"
        echo
        echo '```'
        head -n 40 "$OUT/errors.txt"
        echo '```'
    } > "$SUMMARY"
    rm -f "$STEPS" "$OUT"/.timeout-*
    echo
    cat "$SUMMARY"
    if [[ $FAILED -ne 0 ]]; then
        exit 1
    fi
    exit 0
}

# --- проверка Xcode ---

if [[ -n "${DEVELOPER_DIR:-}" && ! -d "$DEVELOPER_DIR" ]]; then
    {
        echo "# WaveFeels mac CI: $MODE"
        echo
        echo "- result: failure"
        echo "- DEVELOPER_DIR not found: $DEVELOPER_DIR"
        echo
        echo "Xcode on this image:"
        echo
        echo '```'
        ls -d /Applications/Xcode* 2>&1
        echo '```'
    } > "$SUMMARY"
    cat "$SUMMARY"
    exit 1
fi

trap finish EXIT

run_step toolchain 60 "$OUT/toolchain.txt" toolchain_info

# --- шаги режимов ---

step_tests() {
    if run_step build-tests "$LIMIT_BUILD" "$OUT/build.log" swift build --build-tests; then
        run_step test "$LIMIT_TEST" "$OUT/test.log" swift test --skip-build
    else
        skip test "test build failed"
    fi
}

step_release() {
    run_step build-release "$LIMIT_BUILD" "$OUT/build.log" swift build -c release
}

# Бандл, подпись, снимки и пробный запуск из бандла. Возвращает 0, если бандл подписан.
step_bundle() {
    if ! run_step bundle "$LIMIT_SMALL" "$OUT/bundle.log" bash scripts/bundle.sh "$VERSION" "$BUILD"; then
        skip sign "bundle failed"
        skip snapshots "bundle failed"
        skip smoke "bundle failed"
        return 1
    fi
    local signed=0
    if run_step sign "$LIMIT_SIGN" "$OUT/sign.txt" bash scripts/sign.sh "$APP"; then
        signed=1
    fi
    if has_snapshot_renderer; then
        run_step snapshots "$LIMIT_SNAPSHOTS" "$OUT/snapshots.log" render_snapshots
    else
        skip snapshots "app has no --render-snapshots yet"
    fi
    run_step smoke 60 "$OUT/smoke.log" smoke_launch
    if [[ -f "$APP_LOG" ]]; then
        cp "$APP_LOG" "$OUT/app.log"
    fi
    [[ $signed -eq 1 ]]
}

# Печатает designated requirement обеих копий: по нему TCC узнает приложение после обновления.
log_requirements() { # основное приложение, копия для обновления
    local main update
    main=$(codesign -dr - "$1" 2>&1 | grep '^designated' || true)
    update=$(codesign -dr - "$2" 2>&1 | grep '^designated' || true)
    echo "designated requirement (main): ${main:-none}"
    echo "designated requirement (update-test): ${update:-none}"
    if [[ -n "$main" && "$main" == "$update" ]]; then
        echo "designated requirements match: yes"
    else
        echo "designated requirements match: NO"
    fi
}

# Вторая копия для проверки обновления. Возвращает 0, если она собрана и подписана.
step_update_test() {
    if ! run_step bundle-update-test "$LIMIT_SMALL" "$OUT/bundle.log" \
        bash scripts/bundle.sh "$VERSION" "$UPDATE_BUILD" "$UPDATE_APP"; then
        skip sign-update-test "bundle failed"
        skip zip-update-test "bundle failed"
        return 1
    fi
    if ! run_step sign-update-test "$LIMIT_SIGN" "$OUT/sign.txt" bash scripts/sign.sh "$UPDATE_APP"; then
        skip zip-update-test "sign failed"
        return 1
    fi
    run_step requirements "$LIMIT_SMALL" "$OUT/sign.txt" log_requirements "$APP" "$UPDATE_APP"
    run_step zip-update-test "$LIMIT_SMALL" "$OUT/zip.log" \
        ditto -c -k --keepParent "$UPDATE_APP" "$ROOT/dist/WaveFeels-$REF_SAFE-update-test.zip"
}

skip_bundle() { # причина
    skip bundle "$1"
    skip sign "$1"
    skip snapshots "$1"
    skip smoke "$1"
}

case "$MODE" in
    fast)
        step_tests
        ;;
    snap)
        if step_release; then
            step_bundle
        else
            skip_bundle "release build failed"
        fi
        ;;
    full)
        if [[ -f scripts/build-adapter.sh ]]; then
            run_step adapter "$LIMIT_BUILD" "$OUT/adapter.log" bash scripts/build-adapter.sh
        else
            skip adapter "scripts/build-adapter.sh not present"
        fi
        release_ok=0
        if step_release; then
            release_ok=1
        fi
        step_tests
        app_ok=0
        if [[ $release_ok -eq 1 ]]; then
            if step_bundle; then
                app_ok=1
            fi
        else
            skip_bundle "release build failed"
        fi
        if [[ $app_ok -eq 1 && -f scripts/cpu-probe.sh ]]; then
            run_step cpu "$LIMIT_CPU" "$OUT/cpu.txt" bash scripts/cpu-probe.sh "$APP"
        elif [[ $app_ok -eq 1 ]]; then
            skip cpu "scripts/cpu-probe.sh not present"
        else
            skip cpu "no signed app"
        fi
        if [[ $app_ok -eq 1 ]]; then
            run_step zip "$LIMIT_SMALL" "$OUT/zip.log" \
                ditto -c -k --keepParent "$APP" "$ROOT/dist/WaveFeels-$REF_SAFE.zip"
        else
            skip zip "no signed app"
        fi
        if [[ -n "${RELEASE:-}" ]]; then
            if [[ $app_ok -eq 1 ]]; then
                step_update_test
            else
                skip bundle-update-test "no signed app"
            fi
        fi
        ;;
esac
