#!/usr/bin/env bash
# Замер CPU и памяти собранного приложения. Использование:
#   scripts/cpu-probe.sh [--preset default|max] [--sample] <WaveFeels.app> [секунды]
#
# Приложение читает настройки не из настроек пользователя, а из отдельного набора
# com.wfeels.wavefeels.benchmark (--settings-suite), поэтому числа сравнимы между маками и
# коммитами. Перед замером набор удаляется целиком и заполняется заново через `defaults write`
# (настройки кэширует cfprefsd, поэтому файл plist напрямую не правится):
#   default: вид 1.1 по умолчанию (линий 3, заливка 0, радиус свечения 1, свечение 0.6, крылья 64,
#            толщина 1, амплитуда 1); предел play 15 %, итог в cpu.txt;
#   max:     верхние границы диапазонов (линий 6, заливка 1, радиус свечения 3, свечение 1, крылья
#            200, толщина 2, амплитуда 2); предел play 20 %, итог в cpu-max.txt.
# В обоих наборах «вздох» включен, пауза выключена. Содержимое набора (`defaults read`) пишется в
# начало отчета, а действующие значения приложение пишет в свой лог строкой «настройки из набора
# ...». Прогон без этой строки считается проваленным: сборка без --settings-suite мерила бы
# настройки пользователя.
#
# Два прогона, каждый со своим процессом приложения:
#   play:    --demo Demo/demo.wav --fake-notch --exit-after <секунды+10>; среднее выше предела
#            набора (15 или 20 % одного ядра) считается провалом. Остров обязан появиться (строка
#            «остров: скрыт -> ...» в логе приложения), иначе замер ничего не говорит и тоже
#            считается провалом.
#   silence: --demo Demo/silence.wav --fake-notch --no-capture --exit-after <секунды+10> (с
#            --sample <секунды+20>); среднее должно быть меньше 1 % в обоих наборах. Остров обязан
#            остаться скрытым (ни одного перехода из «скрыт»): в тишине анализ идет с частотой 15 Гц
#            вместо 60 и ничего не рисуется, иначе замер не про простой.
# Демо никогда не создает tap, поэтому захват звука в CI не запускается. С другим запущенным
# WaveFeels (например, из «Программ») скрипт не работает: тот пишет в тот же лог и грузит процессор.
#
# CPU считается как прирост накопленного процессорного времени (`ps -o time=`) за окно в
# <секунды> (по умолчанию 30) после прогрева 5 с, деленный на прошедшее время. `%cpu` из `ps` не
# годится: это затухающее среднее. Внутри окна раз в секунду пишется загрузка за эту секунду и RSS
# (`ps -o rss=`). С --sample `sample <pid> 5` снимает стеки всех потоков: в play в середине окна,
# в silence сразу после окна (сам sample грузит процессор и исказил бы замер в тишине, поэтому
# приложение в этом прогоне живет на 10 с дольше). Итоги по потокам и самые частые функции на
# вершине стека идут в cpu-sample.txt (play) и cpu-sample-silence.txt, полный вывод в
# cpu-sample.raw.txt и cpu-sample-silence.raw.txt; у набора max те же файлы начинаются с cpu-max
# (cpu-max-sample.txt и так далее). Фоновый сторож убивает приложение вместе с потомками через
# 10 с после его --exit-after (в macOS нет timeout).
#
# Итог в $OUT/cpu.txt или $OUT/cpu-max.txt (по умолчанию каталог ci-out), он же печатается в
# stdout. Код 0, если оба прогона в пределах, 1 при провале, 2 при ошибке вызова или записи набора.
# Рассчитан на bash 3.2 и BSD-утилиты.
set -uo pipefail

usage() {
    echo "usage: $0 [--preset default|max] [--sample] <WaveFeels.app> [seconds]" >&2
    exit 2
}

PRESET=default
SAMPLE=0
APP_ARG=""
DURATION=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --preset)
            [[ $# -ge 2 ]] || usage
            PRESET=$2
            shift 2
            ;;
        --sample)
            SAMPLE=1
            shift
            ;;
        -*)
            echo "cpu-probe: unknown option $1" >&2
            usage
            ;;
        *)
            if [[ -z "$APP_ARG" ]]; then
                APP_ARG=$1
            elif [[ -z "$DURATION" ]]; then
                DURATION=$1
            else
                usage
            fi
            shift
            ;;
    esac
done

case "$PRESET" in
    default)
        PLAY_LIMIT=15
        PREFIX=cpu
        ;;
    max)
        PLAY_LIMIT=20
        PREFIX=cpu-max
        ;;
    *)
        echo "cpu-probe: unknown preset $PRESET (expected default or max)" >&2
        usage
        ;;
esac

[[ -n "$APP_ARG" && -d "$APP_ARG" ]] || usage
APP=$(cd "$APP_ARG" && pwd) || usage
DURATION=${DURATION:-30}
[[ "$DURATION" =~ ^[0-9]+$ && $DURATION -ge 5 ]] || usage

WARMUP=5
SILENCE_LIMIT=1
SAMPLE_SECONDS=5
SAMPLE_LIMIT=60
# Набор настроек замера и строка, которой приложение сообщает о нем в лог (AppDelegate.logSettings).
SUITE=com.wfeels.wavefeels.benchmark
SETTINGS_MARK="настройки из набора $SUITE: "

cd "$(dirname "$0")/.." || exit 2
OUT=${OUT:-$PWD/ci-out}
mkdir -p "$OUT"
REPORT="$OUT/$PREFIX.txt"
BIN="$APP/Contents/MacOS/WaveFeels"
DEMO_DIR="$APP/Contents/Resources/Demo"
APP_LOG="$HOME/Library/Logs/WaveFeels/wavefeels.log"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

for file in "$BIN" "$DEMO_DIR/demo.wav" "$DEMO_DIR/silence.wav"; do
    if [[ ! -e "$file" ]]; then
        echo "cpu-probe: missing $file" >&2
        exit 2
    fi
done

# Другой экземпляр пишет в тот же лог (переходы острова, строка настроек) и грузит процессор.
OTHERS=$(pgrep -x WaveFeels 2>/dev/null | tr '\n' ' ')
if [[ -n "$OTHERS" ]]; then
    echo "cpu-probe: WaveFeels is already running (pid ${OTHERS% }), quit it first: it shares the log and the CPU" >&2
    exit 2
fi

# Заполняет набор замера заново. Удаляется только он, настройки пользователя
# (com.wfeels.wavefeels) не трогаются; `defaults delete` несуществующего набора просто
# возвращает ошибку. Числа пишутся как -float и -int: AppSettings читает их через
# `double(forKey:)` и NSNumber и ограничивает теми же диапазонами, что и ползунки.
write_preset() {
    local lines fill radius glow wings thickness amplitude
    if [[ $PRESET == max ]]; then
        lines=6 fill=1 radius=3 glow=1 wings=200 thickness=2 amplitude=2
    else
        lines=3 fill=0 radius=1 glow=0.6 wings=64 thickness=1 amplitude=1
    fi
    defaults delete "$SUITE" > /dev/null 2>&1
    defaults write "$SUITE" wf.lineCount -int "$lines" &&
        defaults write "$SUITE" wf.fill -float "$fill" &&
        defaults write "$SUITE" wf.glowRadius -float "$radius" &&
        defaults write "$SUITE" wf.glowIntensity -float "$glow" &&
        defaults write "$SUITE" wf.wingWidth -float "$wings" &&
        defaults write "$SUITE" wf.lineThickness -float "$thickness" &&
        defaults write "$SUITE" wf.waveAmplitude -float "$amplitude" &&
        defaults write "$SUITE" wf.beatPulse -bool true &&
        defaults write "$SUITE" wf.paused -bool false
}

if ! write_preset; then
    echo "cpu-probe: defaults write $SUITE failed" >&2
    exit 2
fi

FAILED=0

report() {
    printf '%s\n' "$*" | tee -a "$REPORT"
}

now_ms() {
    perl -MTime::HiRes=time -e 'printf "%d\n", time * 1000'
}

# Накопленное процессорное время в сотых долях секунды; пусто, если процесса нет.
# Формат `ps -o time=`: [дни-][[часы:]минуты:]секунды[.доли], в macOS обычно «M:SS.ss».
cpu_cs() {
    ps -o time= -p "$1" 2>/dev/null | awk '
        NF {
            t = $1; days = 0
            if (index(t, "-")) { split(t, d, "-"); days = d[1]; t = d[2] }
            n = split(t, p, ":"); s = 0
            for (i = 1; i <= n; i++) s = s * 60 + p[i]
            printf "%d\n", (days * 86400 + s) * 100 + 0.5
        }'
}

rss_kb() {
    ps -o rss= -p "$1" 2>/dev/null | tr -d ' '
}

descendants() { # pid: печатает всех потомков процесса
    local child
    for child in $(pgrep -P "$1" 2>/dev/null); do
        echo "$child"
        descendants "$child"
    done
}

# Сумма процессорного времени потомков (процессы perl адаптера Now Playing), сотые доли секунды.
children_cs() {
    local total=0 child cs
    for child in $(descendants "$1"); do
        cs=$(cpu_cs "$child")
        total=$((total + ${cs:-0}))
    done
    echo "$total"
}

percent() { # сотые доли секунды CPU, миллисекунды времени
    awk -v cs="$1" -v ms="$2" 'BEGIN { if (ms <= 0) ms = 1; printf "%.2f\n", cs * 1000 / ms }'
}

mb() {
    awk -v kb="$1" 'BEGIN { printf "%.1f MB\n", kb / 1024 }'
}

log_lines() {
    if [[ -f "$APP_LOG" ]]; then
        wc -l < "$APP_LOG" | tr -d ' '
    else
        echo 0
    fi
}

watchdog() { # pid, лимит в секундах
    local deadline=$((SECONDS + $2)) tree
    while kill -0 "$1" 2>/dev/null; do
        if [[ $SECONDS -ge $deadline ]]; then
            echo "watchdog: pid $1 exceeded $2 s, terminating it and its children" >&2
            # Дерево собирается до TERM: после смерти родителя потомки (perl адаптера) уходят к launchd.
            tree="$1 $(descendants "$1" | tr '\n' ' ')"
            # shellcheck disable=SC2086 # список pid нужно разбить на отдельные аргументы
            kill -TERM $tree 2>/dev/null
            sleep 5
            # shellcheck disable=SC2086 # то же
            kill -KILL $tree 2>/dev/null
            return 0
        fi
        sleep 1
    done
}

# Сжатый вывод sample: заголовок, число сэмплов по каждому потоку (верхние строки «Call graph»
# с именем потока и очереди) и раздел «Sort by top of stack»: самые частые функции на вершине
# стека со счетчиками. Всего около 120 строк, длинные строки обрезаются.
trim_sample() { # файл sample
    awk '
        /^Call graph:/ { section = "graph"; print "Samples per thread:"; next }
        /^Total number in stack/ { section = "skip"; next }
        /^Sort by top of stack/ { section = "top"; shown = 0; print ""; print; next }
        /^Binary Images:/ { section = "done"; next }
        section == "" && NR <= 20 { print; next }
        section == "graph" && /^    [0-9]+ Thread_/ && threads < 30 { print substr($0, 1, 200); threads++; next }
        section == "top" && shown < 70 && NF { print substr($0, 1, 200); shown++; next }
    ' "$1"
}

# Запускает sample в фоне, pid в SAMPLE_PID и SAMPLE_WD (не через $(...): подстановка ждала бы
# фоновые процессы, а wait не видит внуков). Приложение в это время живо еще около 15 с, поэтому
# -mayDie не нужен: с ним sample на раннере отдавал заголовок без стеков.
SAMPLE_PID=""
SAMPLE_WD=""
take_sample() { # pid
    sample "$1" "$SAMPLE_SECONDS" -file "$TMP/sample.txt" > "$TMP/sample.log" 2>&1 &
    SAMPLE_PID=$!
    watchdog "$SAMPLE_PID" "$SAMPLE_LIMIT" > /dev/null 2>&1 &
    SAMPLE_WD=$!
}

finish_sample() { # имя прогона
    local rc report raw
    wait "$SAMPLE_PID" 2>/dev/null
    rc=$?
    kill "$SAMPLE_WD" 2>/dev/null
    wait "$SAMPLE_WD" 2>/dev/null
    SAMPLE_PID=""
    SAMPLE_WD=""
    if [[ $1 == play ]]; then
        report="$OUT/$PREFIX-sample.txt"
        raw="$OUT/$PREFIX-sample.raw.txt"
    else
        report="$OUT/$PREFIX-sample-$1.txt"
        raw="$OUT/$PREFIX-sample-$1.raw.txt"
    fi
    if [[ -f "$TMP/sample.txt" ]]; then
        mv "$TMP/sample.txt" "$raw"
    else
        : > "$raw"
    fi
    {
        echo "# sample <pid> $SAMPLE_SECONDS of the $1 run: samples per thread and heaviest top-of-stack frames"
        echo
        if grep -q 'Thread_' "$raw"; then
            trim_sample "$raw"
        else
            echo "no stacks in sample output (sample exit $rc)"
            echo
            echo "first 60 lines of $(basename "$raw"):"
            head -n 60 "$raw"
            echo
            echo "sample stdout/stderr:"
            cat "$TMP/sample.log"
        fi
    } > "$report"
}

# Один прогон: имя, предел среднего в процентах, сравнение (max: не больше предела, below: строго
# меньше), каким должен быть остров (shown или hidden), когда снимать стеки (window: в середине
# окна, after: сразу после него), через сколько секунд приложение выходит само (--exit-after),
# остальные аргументы приложения.
probe() {
    local name=$1 limit=$2 compare=$3 expect_island=$4 sample_at=$5 exit_after=$6
    shift 6
    local log_start pid wd rc t0 c0 k0 t1 c1 k1 t c r prev_t prev_c sec
    local per_second="" max_sec=0 rss_first="" rss_last=0 rss_max=0 alive=1 sampled=0
    local average children verdict=ok reasons="" app_log="$TMP/$name.log" settings_line

    report ""
    report "## $name"
    report ""
    report "args: $* --settings-suite $SUITE --exit-after $exit_after"

    log_start=$(log_lines)
    "$BIN" "$@" --settings-suite "$SUITE" --exit-after "$exit_after" > "$TMP/$name.stdout" 2>&1 &
    pid=$!
    watchdog "$pid" $((exit_after + 10)) 2>> "$TMP/$name.stdout" &
    wd=$!

    sleep "$WARMUP"
    t0=$(now_ms)
    c0=$(cpu_cs "$pid")
    k0=$(children_cs "$pid")
    if [[ -z "$c0" ]]; then
        alive=0
        c0=0
    fi
    prev_t=$t0
    prev_c=$c0
    t1=$t0
    c1=$c0
    k1=$k0
    while [[ $alive -eq 1 && $(($(now_ms) - t0)) -lt $((DURATION * 1000)) ]]; do
        sleep 1
        t=$(now_ms)
        c=$(cpu_cs "$pid")
        if [[ -z "$c" ]]; then
            alive=0
            break
        fi
        k1=$(children_cs "$pid")
        r=$(rss_kb "$pid")
        r=${r:-0}
        sec=$(percent $((c - prev_c)) $((t - prev_t)))
        per_second="$per_second $sec"
        max_sec=$(awk -v a="$max_sec" -v b="$sec" 'BEGIN { print (b > a) ? b : a }')
        rss_first=${rss_first:-$r}
        rss_last=$r
        if [[ $r -gt $rss_max ]]; then
            rss_max=$r
        fi
        t1=$t
        c1=$c
        prev_t=$t
        prev_c=$c
        if [[ $SAMPLE -eq 1 && $sample_at == window && $sampled -eq 0 && $((t - t0)) -ge $((DURATION * 500)) ]]; then
            sampled=1
            take_sample "$pid"
        fi
    done
    if [[ $SAMPLE -eq 1 && $sample_at == after && $alive -eq 1 ]]; then
        sampled=1
        take_sample "$pid"
    fi

    wait "$pid"
    rc=$?
    kill "$wd" 2>/dev/null
    wait "$wd" 2>/dev/null
    if [[ $sampled -eq 1 ]]; then
        finish_sample "$name"
    fi
    if [[ -f "$APP_LOG" ]]; then
        tail -n +"$((log_start + 1))" "$APP_LOG" > "$app_log"
    else
        : > "$app_log"
    fi

    average=$(percent $((c1 - c0)) $((t1 - t0)))
    children=$(percent $((k1 > k0 ? k1 - k0 : 0)) $((t1 - t0)))
    report "window: $(((t1 - t0) / 1000)) s after ${WARMUP} s warm-up"
    if [[ $compare == max ]]; then
        report "average: $average % of one core (limit: at most $limit %)"
    else
        report "average: $average % of one core (limit: below $limit %)"
    fi
    report "max per second: $max_sec %"
    report "per second:$per_second"
    report "child processes (Now Playing adapter): $children % of one core"
    report "rss: first $(mb "${rss_first:-0}"), last $(mb "$rss_last"), max $(mb "$rss_max")"
    report "app exit code: $rc"

    if [[ $alive -eq 0 ]]; then
        reasons="$reasons; app exited before the window ended"
    fi
    if [[ $rc -ne 0 ]]; then
        reasons="$reasons; app exit code $rc"
    fi
    settings_line=$(grep -F "$SETTINGS_MARK" "$app_log" | tail -n 1)
    if [[ -n "$settings_line" ]]; then
        report "effective settings: ${settings_line#*"$SETTINGS_MARK"}"
    else
        report "effective settings: not reported"
        reasons="$reasons; app did not report settings from $SUITE (build without --settings-suite?), the run may have used personal settings"
    fi
    if awk -v a="$average" -v l="$limit" -v c="$compare" 'BEGIN { exit !(c == "max" ? a > l : a >= l) }'; then
        reasons="$reasons; average $average % is over the limit of $limit %"
    fi
    # Любой переход из «скрыт» (в «свернут» или «раскрыт») значит, что остров показан.
    if grep -q 'остров: скрыт -> ' "$app_log"; then
        report "island: shown (expected $expect_island)"
        if [[ $expect_island == hidden ]]; then
            reasons="$reasons; island appeared in silence"
        fi
    else
        report "island: hidden (expected $expect_island)"
        if [[ $expect_island == shown ]]; then
            reasons="$reasons; island never appeared, the measurement does not cover drawing"
        fi
    fi
    if [[ -n "$reasons" ]]; then
        verdict="FAIL (${reasons#; })"
        FAILED=1
    fi
    report "verdict: $verdict"
    report ""
    report "app log:"
    report "$(cat "$app_log")"
    if [[ -s "$TMP/$name.stdout" ]]; then
        report ""
        report "app stdout/stderr (last 20 lines):"
        report "$(tail -n 20 "$TMP/$name.stdout")"
    fi
}

: > "$REPORT"
report "# WaveFeels CPU probe"
report ""
report "app: $APP"
report "preset: $PRESET (play: at most $PLAY_LIMIT %, silence: below $SILENCE_LIMIT %)"
report "method: cumulative CPU time from ps over a ${DURATION} s window after ${WARMUP} s warm-up, % of one core"
report "machine: $(sysctl -n machdep.cpu.brand_string 2>/dev/null || uname -m), $(sysctl -n hw.ncpu 2>/dev/null || echo '?') cores, macOS $(sw_vers -productVersion 2>/dev/null || echo '?')"
report ""
report "defaults read $SUITE:"
report "$(defaults read "$SUITE" 2>&1)"

EXIT_AFTER=$((DURATION + 10))
# С --sample в тишине стеки снимаются после окна, на это приложению нужны лишние 10 с.
SILENCE_EXIT_AFTER=$EXIT_AFTER
if [[ $SAMPLE -eq 1 ]]; then
    SILENCE_EXIT_AFTER=$((EXIT_AFTER + 10))
fi
probe play "$PLAY_LIMIT" max shown window "$EXIT_AFTER" --demo "$DEMO_DIR/demo.wav" --fake-notch
probe silence "$SILENCE_LIMIT" below hidden after "$SILENCE_EXIT_AFTER" --demo "$DEMO_DIR/silence.wav" --fake-notch --no-capture

report ""
if [[ $FAILED -eq 0 ]]; then
    report "result: success"
    exit 0
fi
report "result: failure"
exit 1
