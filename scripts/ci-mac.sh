#!/usr/bin/env bash
# Все шаги mac-сборки в одном месте. Использование:
#   scripts/ci-mac.sh <fast|snap|full>                 все фазы подряд (локальный запуск)
#   scripts/ci-mac.sh build <fast|snap|full>           без секретов: адаптер, сборка, тесты, бандл
#   scripts/ci-mac.sh sign <fast|snap|full>            подпись бандла (единственная фаза с ключом)
#   scripts/ci-mac.sh check <fast|snap|full>           снимки, пробный запуск, замер CPU, zip
#   scripts/ci-mac.sh sign-and-check <fast|snap|full>  фазы sign и check одним вызовом
# Режимы:
#   fast: swift build --build-tests, swift test --skip-build
#   snap: swift build -c release, bundle.sh, sign.sh, снимки и пробный запуск из бандла
#   full: адаптер, release-сборка, тесты, бандл, подпись, снимки, пробный запуск, замер CPU, zip
# Фазы нужны, чтобы секреты подписи попадали только в шаг подписи: в workflow каждая фаза идет
# отдельным шагом, а шаги build и check ключа не получают. Скрипт сам убирает SIGNING_P12_BASE64
# и SIGNING_P12_PASSWORD из своего окружения при старте и отдает их только sign.sh (sign_app).
# Состояние между фазами лежит в ci-out/ (.state, .steps.md, .duration): фаза build очищает
# каталог, остальные дописывают. Если build не дошла до конца, sign и check это отмечают и падают.
# С RELEASE=1 (release.yml) режим full дополнительно собирает вторую копию для проверки обновления:
# тот же бинарник, CFBundleVersion "<номер запуска>1", dist/update-test/WaveFeels.app (фаза build),
# ее подпись (фаза sign) и архив dist/WaveFeels-<тег>-update-test.zip (фаза check).
# Designated requirement обеих копий пишется в sign.txt.
# Результаты в ci-out/: summary.md, errors.txt, build.log, test.log, sign.txt, snapshots/, cpu.txt,
# cpu-sample*.txt; с SAMPLE_TESTS=1 еще test-sample.txt и test-sample-2.txt (стеки процесса тестов).
# С CPU_MAX=1 режим full после обычного замера CPU (набор настроек default) отдельным шагом
# меряет набор max: cpu-max.txt и cpu-max-sample*.txt. По умолчанию этот шаг не идет, он
# занимает еще около 95 с.
# Каждый шаг идет под своим лимитом времени (в macOS нет timeout, работает фоновый сторож).
# Шаги из будущих задач (--render-snapshots, cpu-probe.sh) пропускаются, пока их нет,
# с отметкой skipped в summary.md. Адаптер (build-adapter.sh) собирается только в режиме full,
# в остальных режимах бандл идет без него.
# Скрипт рассчитан на bash 3.2 и BSD-утилиты.
set -uo pipefail

usage() {
    echo "usage: $0 [build|sign|check|sign-and-check] <fast|snap|full>" >&2
    exit 2
}

case "${1:-fast}" in
    fast | snap | full)
        PHASES="build sign check"
        MODE=${1:-fast}
        ;;
    build | sign | check)
        PHASES=$1
        MODE=${2:-fast}
        ;;
    sign-and-check)
        PHASES="sign check"
        MODE=${2:-fast}
        ;;
    *) usage ;;
esac
case "$MODE" in
    fast | snap | full) ;;
    *) usage ;;
esac

# Ключ подписи забирается из окружения сразу: build и check его не видят (и их дочерние
# процессы тоже), sign.sh получает его только через sign_app. Пустая строка значит "не задан".
SIGN_P12_B64=${SIGNING_P12_BASE64:-}
SIGN_P12_PW=${SIGNING_P12_PASSWORD:-}
unset SIGNING_P12_BASE64 SIGNING_P12_PASSWORD

cd "$(dirname "$0")/.." || exit 1
ROOT=$PWD
OUT="$ROOT/ci-out"
export OUT
case " $PHASES " in
    *" build "*)
        rm -rf "$OUT"
        mkdir -p "$OUT/snapshots"
        ;;
    *)
        if [[ ! -d "$OUT" ]]; then
            echo "error: $OUT not found, run the build phase first" >&2
            exit 1
        fi
        ;;
esac

SUMMARY="$OUT/summary.md"
STEPS="$OUT/.steps.md"
STATE="$OUT/.state"
DURATION_FILE="$OUT/.duration"
touch "$STEPS" "$STATE"
START=$SECONDS
FAILED=0

mark() { # отметка состояния, видимая следующим фазам
    echo "$1" >> "$STATE"
}

marked() { # 0, если отметка стоит
    grep -qx "$1" "$STATE" 2> /dev/null
}

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
# Бандл в первый раз еще и компилирует и запускает scripts/make-icon.swift.
LIMIT_BUNDLE=240
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

# Приложение до отрисовки пишет manifest.txt со списком PNG; шаг проходит, только если
# список не пуст и каждый файл из него на месте и не пустой. Нарисованную иконку (icon.png и
# icon-sizes.png кладет bundle.sh) скрипт дописывает в список сам. Превью icon-macos26*.png
# в список не входят: их рисует Icon Composer, если он есть в Xcode.
render_snapshots() {
    local dir="$OUT/snapshots" manifest expected=0 missing=0 name
    manifest="$dir/manifest.txt"
    "$APP/Contents/MacOS/WaveFeels" --render-snapshots "$dir" --no-capture --exit-after 60 || return $?
    if [[ ! -f "$manifest" ]]; then
        echo "snapshots: manifest.txt missing"
        return 1
    fi
    if [[ ! -f Resources/AppIcon.icns ]]; then
        printf '%s\n' icon.png icon-sizes.png >> "$manifest"
    fi
    while IFS= read -r name; do
        [[ -n "$name" ]] || continue
        expected=$((expected + 1))
        if [[ ! -s "$dir/$name" ]]; then
            echo "snapshots: missing $name"
            missing=$((missing + 1))
        fi
    done < "$manifest"
    echo "snapshots: $((expected - missing)) of $expected"
    [[ $expected -gt 0 && $missing -eq 0 ]]
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
    local result=success total prev=0 phase
    if [[ $FAILED -ne 0 ]]; then
        touch "$OUT/.failed"
    fi
    if [[ -f "$OUT/.failed" ]]; then
        result=failure
    fi
    for phase in $PHASES; do
        mark "phase-$phase"
    done
    if [[ -f "$DURATION_FILE" ]]; then
        prev=$(cat "$DURATION_FILE")
    fi
    total=$((prev + SECONDS - START))
    echo "$total" > "$DURATION_FILE"
    write_errors
    {
        echo "# WaveFeels mac CI: $MODE"
        echo
        echo "- result: $result"
        echo "- ref: $REF"
        echo "- sha: $SHA"
        echo "- run: ${GITHUB_RUN_NUMBER:-local} attempt ${GITHUB_RUN_ATTEMPT:-1}"
        echo "- app version: $VERSION (build $BUILD)"
        echo "- duration: $total s"
        echo "- phases run: $(grep '^phase-' "$STATE" | sed 's/^phase-//' | tr '\n' ' ')"
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
    rm -f "$OUT"/.timeout-*
    if marked phase-build && marked phase-check; then
        rm -f "$STEPS" "$STATE" "$DURATION_FILE" "$OUT/.failed"
    fi
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

# --- снимки стеков процесса тестов ---

# Сжатый вывод sample: заголовок, число сэмплов по каждому потоку, дерево вызовов главного
# потока (первый поток в «Call graph») и самые частые функции на вершине стека.
trim_test_sample() { # файл sample
    awk '
        /^Call graph:/ { section = "graph"; print "Samples per thread:"; next }
        /^Total number in stack/ { section = "skip"; next }
        /^Sort by top of stack/ { section = "top"; shown = 0; print ""; print; next }
        /^Binary Images:/ { section = "done"; next }
        section == "" && NR <= 20 { print; next }
        section == "graph" && /^    [0-9]+ Thread_/ {
            if (threads < 60) print substr($0, 1, 200)
            threads++
            in_main = (threads == 1)
            next
        }
        section == "graph" && in_main && main_lines < 250 { tree[++main_lines] = substr($0, 1, 250); next }
        section == "top" && shown < 80 && NF { print substr($0, 1, 200); shown++; next }
        END {
            print ""
            print "Main thread call tree:"
            for (i = 1; i <= main_lines; i++) print tree[i]
        }
    ' "$1"
}

# С SAMPLE_TESTS=1 через 8 и 20 с после старта `swift test` снимает стеки процесса тестов
# (swiftpm-testing-helper для Swift Testing, иначе xctest) на 4 с в test-sample.txt и
# test-sample-2.txt. Нужно для разбора зависаний тестов, по умолчанию выключено. На исход шага не
# влияет: файл с ошибкой тоже результат.
sample_tests() { # pid swift test
    local start=$SECONDS at file target raw="$OUT/.test-sample.raw"
    for at in 8 20; do
        if [[ $at -eq 8 ]]; then file="$OUT/test-sample.txt"; else file="$OUT/test-sample-2.txt"; fi
        while [[ $((SECONDS - start)) -lt $at ]] && kill -0 "$1" 2>/dev/null; do
            sleep 1
        done
        kill -0 "$1" 2>/dev/null || return 0
        target=$(pgrep -n -f swiftpm-testing-helper || pgrep -n xctest)
        if [[ -z "$target" ]]; then
            echo "no test runner process at $at s" > "$file"
            continue
        fi
        rm -f "$raw"
        {
            echo "# sample $target 4 -mayDie at $at s after swift test started"
            ps -o pid=,etime=,command= -p "$target" | cut -c1-200
            echo
            if sample "$target" 4 -mayDie -file "$raw" > /dev/null 2>&1 && [[ -s "$raw" ]]; then
                trim_test_sample "$raw"
            else
                echo "sample failed"
            fi
        } > "$file" 2>&1
        rm -f "$raw"
    done
}

run_tests() {
    local pid sampler rc
    if [[ "${SAMPLE_TESTS:-0}" != 1 ]]; then
        swift test --skip-build
        return
    fi
    swift test --skip-build &
    pid=$!
    sample_tests "$pid" > /dev/null 2>&1 &
    sampler=$!
    wait "$pid"
    rc=$?
    wait "$sampler" 2>/dev/null
    return "$rc"
}

# --- шаги режимов ---

step_tests() {
    if run_step build-tests "$LIMIT_BUILD" "$OUT/build.log" swift build --build-tests; then
        run_step test "$LIMIT_TEST" "$OUT/test.log" run_tests
    else
        skip test "test build failed"
    fi
}

step_release() {
    run_step build-release "$LIMIT_BUILD" "$OUT/build.log" swift build -c release
}

# Сборка адаптера: чужой код, поэтому идет без файлов команд GitHub Actions (через них шаг мог бы
# подложить переменные и PATH следующим шагам) и без токенов раннера. Секретов подписи в этой
# фазе в окружении уже нет.
adapter_build() {
    env -u GITHUB_ENV -u GITHUB_PATH -u GITHUB_OUTPUT -u GITHUB_STATE -u GITHUB_STEP_SUMMARY \
        -u ACTIONS_RUNTIME_TOKEN -u ACTIONS_RUNTIME_URL -u ACTIONS_RESULTS_URL \
        -u ACTIONS_ID_TOKEN_REQUEST_TOKEN -u ACTIONS_ID_TOKEN_REQUEST_URL \
        bash scripts/build-adapter.sh
}

# Подпись одной копии приложения. Ключ попадает в окружение только sign.sh; имя функции, а не
# значения, попадает в строку "== step" лога, поэтому в sign.txt секретов нет.
#
# sign.sh идет с фиксированным системным PATH и системным bash: security, codesign, base64,
# openssl, awk, uuidgen, tr и sed лежат в /usr/bin и /bin, и программы из каталогов, которые
# ранние шаги могли дополнить (/opt/homebrew/bin, /usr/local/bin), их подменить не могут.
sign_app() { # app
    env PATH=/usr/bin:/bin:/usr/sbin:/sbin \
        SIGNING_P12_BASE64="$SIGN_P12_B64" SIGNING_P12_PASSWORD="$SIGN_P12_PW" \
        /bin/bash scripts/sign.sh "$1"
}

# Бандл без подписи. Помечает bundle-ok, если он собран.
step_bundle() {
    if run_step bundle "$LIMIT_BUNDLE" "$OUT/bundle.log" \
        env ICON_SNAPSHOT_DIR="$OUT/snapshots" bash scripts/bundle.sh "$VERSION" "$BUILD"; then
        mark bundle-ok
        return 0
    fi
    skip sign "bundle failed"
    skip snapshots "bundle failed"
    skip smoke "bundle failed"
    return 1
}

# Подпись основного бандла (фаза sign). Помечает signed при успехе.
step_sign() {
    if run_step sign "$LIMIT_SIGN" "$OUT/sign.txt" sign_app "$APP"; then
        mark signed
    fi
}

# Снимки и пробный запуск из бандла (фаза check).
step_snapshots_smoke() {
    if has_snapshot_renderer; then
        run_step snapshots "$LIMIT_SNAPSHOTS" "$OUT/snapshots.log" render_snapshots
    else
        skip snapshots "app has no --render-snapshots yet"
    fi
    run_step smoke 60 "$OUT/smoke.log" smoke_launch
    if [[ -f "$APP_LOG" ]]; then
        cp "$APP_LOG" "$OUT/app.log"
    fi
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

# Вторая копия для проверки обновления, фаза build: только бандл. Помечает update-bundle-ok.
step_update_bundle() {
    if run_step bundle-update-test "$LIMIT_BUNDLE" "$OUT/bundle.log" \
        bash scripts/bundle.sh "$VERSION" "$UPDATE_BUILD" "$UPDATE_APP"; then
        mark update-bundle-ok
    else
        skip sign-update-test "bundle failed"
        skip zip-update-test "bundle failed"
    fi
}

# Подпись второй копии и сверка требований, фаза sign. Помечает update-signed.
step_update_sign() {
    if run_step sign-update-test "$LIMIT_SIGN" "$OUT/sign.txt" sign_app "$UPDATE_APP"; then
        mark update-signed
        run_step requirements "$LIMIT_SMALL" "$OUT/sign.txt" log_requirements "$APP" "$UPDATE_APP"
    else
        skip zip-update-test "sign failed"
    fi
}

skip_bundle() { # причина
    skip bundle "$1"
    skip sign "$1"
    skip snapshots "$1"
    skip smoke "$1"
}

# --- фазы ---

phase_build() {
    run_step toolchain 60 "$OUT/toolchain.txt" toolchain_info
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
                run_step adapter "$LIMIT_BUILD" "$OUT/adapter.log" adapter_build
            else
                skip adapter "scripts/build-adapter.sh not present"
            fi
            local release_ok=0
            if step_release; then
                release_ok=1
            fi
            step_tests
            if [[ $release_ok -eq 1 ]]; then
                if step_bundle && [[ -n "${RELEASE:-}" ]]; then
                    step_update_bundle
                fi
            else
                skip_bundle "release build failed"
            fi
            ;;
    esac
    mark build-done
}

# Фаза sign: единственная, где sign.sh получает ключ.
phase_sign() {
    if ! marked build-done; then
        skip sign "build phase did not finish"
        FAILED=1
        return
    fi
    if [[ "$MODE" == fast ]]; then
        return
    fi
    if ! marked bundle-ok; then
        # build уже записала skip для sign.
        return
    fi
    step_sign
    if [[ "$MODE" == full && -n "${RELEASE:-}" ]] && marked update-bundle-ok; then
        if marked signed; then
            step_update_sign
        else
            skip sign-update-test "no signed app"
            skip zip-update-test "no signed app"
        fi
    fi
}

# Фаза check: запуск собранного приложения, замер, архивы. Ключа в окружении нет.
phase_check() {
    if ! marked build-done; then
        skip snapshots "build phase did not finish"
        FAILED=1
        return
    fi
    if [[ "$MODE" == fast ]]; then
        return
    fi
    if ! marked bundle-ok; then
        return
    fi
    step_snapshots_smoke
    if [[ "$MODE" != full ]]; then
        return
    fi
    local app_ok=0
    if marked signed; then
        app_ok=1
    fi
    if [[ $app_ok -eq 1 && -f scripts/cpu-probe.sh ]]; then
        # Итог замера cpu-probe.sh пишет сам в cpu.txt и cpu-sample*.txt, здесь только вывод шага.
        # Замер идет на наборе настроек default (--settings-suite), а не на настройках раннера.
        run_step cpu "$LIMIT_CPU" "$OUT/cpu.log" bash scripts/cpu-probe.sh --preset default --sample "$APP"
        # Набор max занимает еще около 95 с и в лимит шага cpu вместе с default не помещается,
        # поэтому идет отдельным шагом и только с CPU_MAX=1.
        if [[ "${CPU_MAX:-0}" == 1 ]]; then
            run_step cpu-max "$LIMIT_CPU" "$OUT/cpu-max.log" bash scripts/cpu-probe.sh --preset max --sample "$APP"
        fi
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
    if [[ -n "${RELEASE:-}" ]] && marked update-signed; then
        run_step zip-update-test "$LIMIT_SMALL" "$OUT/zip.log" \
            ditto -c -k --keepParent "$UPDATE_APP" "$ROOT/dist/WaveFeels-$REF_SAFE-update-test.zip"
    fi
}

for phase in $PHASES; do
    case "$phase" in
        build) phase_build ;;
        sign) phase_sign ;;
        check) phase_check ;;
    esac
done
