#!/usr/bin/env bash
# Замер CPU и памяти собранного приложения. Использование: scripts/cpu-probe.sh <WaveFeels.app> [секунды]
#
# Два прогона, каждый со своим процессом приложения:
#   play:    --demo Demo/demo.wav --fake-notch --exit-after <секунды+10>; среднее выше 15 % одного
#            ядра считается провалом. Остров обязан появиться (строка «остров: скрыт -> свернут»
#            в логе приложения), иначе замер ничего не говорит и тоже считается провалом.
#   silence: --demo Demo/silence.wav --fake-notch --no-capture --exit-after <секунды+10>; среднее
#            должно быть меньше 1 %. Остров обязан остаться скрытым: в тишине анализ идет с частотой
#            15 Гц вместо 60 и ничего не рисуется, иначе замер не про простой.
# Демо никогда не создает tap, поэтому захват звука в CI не запускается.
#
# CPU считается как прирост накопленного процессорного времени (`ps -o time=`) за окно в
# <секунды> (по умолчанию 30) после прогрева 5 с, деленный на прошедшее время. `%cpu` из `ps` не
# годится: это затухающее среднее. Внутри окна раз в секунду пишется загрузка за эту секунду и RSS
# (`ps -o rss=`). В середине окна прогона play `sample <pid> 3 -mayDie` снимает стеки всех потоков,
# в cpu-sample.txt идут итоги по потокам и самые частые функции на вершине стека. Фоновый сторож убивает приложение через <секунды+20> (в macOS нет timeout).
#
# Итог в $OUT/cpu.txt (по умолчанию ci-out/cpu.txt), он же печатается в stdout. Код 0, если оба
# прогона в пределах, 1 при провале, 2 при ошибке вызова. Рассчитан на bash 3.2 и BSD-утилиты.
set -uo pipefail

usage() {
    echo "usage: $0 <WaveFeels.app> [seconds]" >&2
    exit 2
}

[[ $# -ge 1 && -d "$1" ]] || usage
APP=$(cd "$1" && pwd) || usage
DURATION=${2:-30}
[[ "$DURATION" =~ ^[0-9]+$ && $DURATION -ge 5 ]] || usage

WARMUP=5
PLAY_LIMIT=15
SILENCE_LIMIT=1
SAMPLE_SECONDS=3
SAMPLE_LIMIT=60

cd "$(dirname "$0")/.." || exit 2
OUT=${OUT:-$PWD/ci-out}
mkdir -p "$OUT"
REPORT="$OUT/cpu.txt"
SAMPLE_REPORT="$OUT/cpu-sample.txt"
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
    local deadline=$((SECONDS + $2))
    while kill -0 "$1" 2>/dev/null; do
        if [[ $SECONDS -ge $deadline ]]; then
            echo "watchdog: pid $1 exceeded $2 s, terminating" >&2
            kill -TERM "$1" 2>/dev/null
            sleep 5
            kill -KILL "$1" 2>/dev/null
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
# фоновые процессы, а wait не видит внуков).
SAMPLE_PID=""
SAMPLE_WD=""
take_sample() { # pid
    sample "$1" "$SAMPLE_SECONDS" -mayDie -file "$TMP/sample.txt" > "$TMP/sample.log" 2>&1 &
    SAMPLE_PID=$!
    watchdog "$SAMPLE_PID" "$SAMPLE_LIMIT" > /dev/null 2>&1 &
    SAMPLE_WD=$!
}

finish_sample() {
    wait "$SAMPLE_PID" 2>/dev/null
    local rc=$?
    kill "$SAMPLE_WD" 2>/dev/null
    wait "$SAMPLE_WD" 2>/dev/null
    {
        echo "# sample <pid> $SAMPLE_SECONDS -mayDie of the play run: samples per thread and heaviest top-of-stack frames"
        echo
        if [[ $rc -eq 0 && -s "$TMP/sample.txt" ]]; then
            trim_sample "$TMP/sample.txt"
        else
            echo "sample failed with exit $rc:"
            cat "$TMP/sample.log"
        fi
    } > "$SAMPLE_REPORT"
}

# Один прогон: имя, предел среднего в процентах, сравнение (max: не больше предела, below: строго
# меньше), каким должен быть остров (shown или hidden), аргументы приложения.
probe() {
    local name=$1 limit=$2 compare=$3 expect_island=$4
    shift 4
    local log_start pid wd rc t0 c0 k0 t1 c1 k1 t c r prev_t prev_c sec
    local per_second="" max_sec=0 rss_first="" rss_last=0 rss_max=0 alive=1
    local average children verdict=ok reasons="" app_log="$TMP/$name.log"

    report ""
    report "## $name"
    report ""
    report "args: $*"

    log_start=$(log_lines)
    "$BIN" "$@" > "$TMP/$name.stdout" 2>&1 &
    pid=$!
    watchdog "$pid" $((DURATION + 20)) 2>> "$TMP/$name.stdout" &
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
        if [[ "$name" == play && -z "$SAMPLE_PID" && $((t - t0)) -ge $((DURATION * 500)) ]]; then
            take_sample "$pid"
        fi
    done

    wait "$pid"
    rc=$?
    kill "$wd" 2>/dev/null
    wait "$wd" 2>/dev/null
    if [[ "$name" == play && -n "$SAMPLE_PID" ]]; then
        finish_sample
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
    if awk -v a="$average" -v l="$limit" -v c="$compare" 'BEGIN { exit !(c == "max" ? a > l : a >= l) }'; then
        reasons="$reasons; average $average % is over the limit of $limit %"
    fi
    if grep -q 'остров: скрыт -> свернут' "$app_log"; then
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
report "method: cumulative CPU time from ps over a ${DURATION} s window after ${WARMUP} s warm-up, % of one core"
report "machine: $(sysctl -n machdep.cpu.brand_string 2>/dev/null || uname -m), $(sysctl -n hw.ncpu 2>/dev/null || echo '?') cores, macOS $(sw_vers -productVersion 2>/dev/null || echo '?')"

EXIT_AFTER=$((DURATION + 10))
probe play "$PLAY_LIMIT" max shown --demo "$DEMO_DIR/demo.wav" --fake-notch --exit-after "$EXIT_AFTER"
probe silence "$SILENCE_LIMIT" below hidden --demo "$DEMO_DIR/silence.wav" --fake-notch --no-capture --exit-after "$EXIT_AFTER"

report ""
if [[ $FAILED -eq 0 ]]; then
    report "result: success"
    exit 0
fi
report "result: failure"
exit 1
