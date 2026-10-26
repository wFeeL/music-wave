#!/usr/bin/env bash
# Замер CPU и памяти собранного приложения. Использование:
#   scripts/cpu-probe.sh [--preset default|max|user] [--style waves|spectrum|minimal|pulse]
#                        [--island collapsed|expanded|banner] [--sample] <WaveFeels.app> [секунды]
#   scripts/cpu-probe.sh --help
#
# Приложение читает настройки не из настроек пользователя, а из отдельного набора
# com.wfeels.wavefeels.benchmark (--settings-suite), поэтому числа сравнимы между маками и
# коммитами. Перед замером набор удаляется целиком и заполняется заново через `defaults write`
# (настройки кэширует cfprefsd, поэтому файл plist напрямую не правится):
#   default: вид 1.1 по умолчанию (линий 3, заливка 0, радиус свечения 1, свечение 0.6, крылья 64,
#            толщина 1, амплитуда 1); предел play 15 %, итог в cpu.txt;
#   max:     верхние границы диапазонов (линий 6, заливка 1, радиус свечения 3, свечение 1, крылья
#            200, толщина 2, амплитуда 2, переливание 1); предел play 20 %, итог в cpu-max.txt;
#   user:    настройки владельца: все ключи wf.* из com.wfeels.wavefeels (`defaults export`, из
#            словаря остаются только они, затем `defaults import`), пауза выключается
#            принудительно (wf.paused = 0); предел play 20 %, как у max (диапазоны те же), итог
#            в cpu-user.txt. Так замер видит настоящий вид владельца на демо-звуке.
# В наборах default и max «вздох» и мягкий пульс включены, пауза выключена, стиль не задан
# («Волны» по умолчанию). Содержимое набора (`defaults read`) пишется в начало отчета, а
# действующие значения приложение пишет в свой лог строкой «настройки из набора ...»: стиль, вид,
# переливание и цвет по частотам, крыло, которое рисуется на самом деле, энергосбережение и
# «Уменьшение движения».
# Строка из прогона play попадает в шапку отчета (applied settings). Прогон без этой строки
# считается проваленным: сборка без --settings-suite мерила бы настройки пользователя.
#
# --style <стиль> пишет поверх набора (и поверх настроек владельца в user) стиль волн:
# wf.waveStyle как JSON-данные, строка "spectrum" в кавычках (AppSettings хранит стиль через
# JSONEncoder). Остальные значения набора не меняются, поэтому стили сравниваются на одних и тех же
# настройках. Приложение подтверждает стиль строкой «стиль <стиль>» в «настройках из набора»; без
# нее прогон считается проваленным. К имени итога добавляется стиль (cpu-max-pulse.txt,
# cpu-spectrum-expanded.txt), в шапке отчета строка «style:».
#
# --island <режим> передается приложению только в прогоне play (прогон silence ждет скрытый
# остров) и держит остров через его же машину состояний:
#   collapsed: курсор не раскрывает остров;
#   expanded:  курсор будто стоит в зоне наведения, остров раскрыт; проверяется строкой лога
#              «остров: ... -> раскрыт»;
#   banner:    свернутый остров, раз в 6 с приложение имитирует смену трека; проверяется строкой
#              «баннер нового трека показан», в набор пишется wf.showTrackBanner = 1.
# В collapsed и banner строка «-> раскрыт» значит провал. Итог и стеки с режимом идут в файлы с
# суффиксом режима: cpu-expanded.txt, cpu-user-banner.txt, cpu-max-expanded-sample.txt.
#
# Частота кадров. С --settings-suite приложение раз в 10 с пишет в лог строки «отрисовка,
# свернутый: ...» и «отрисовка, раскрытый: ...» (замер раздела «Отрисовка» и кадров в секунду).
# Из последней строки корзины прогона (раскрытый для --island expanded, иначе свернутый)
# частота кадров и p50 идут в раздел прогона, а из прогона play еще и в шапку отчета (render).
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
# Итог в $OUT/cpu.txt, $OUT/cpu-max.txt или $OUT/cpu-user.txt (по умолчанию каталог ci-out), он
# же печатается в stdout. Код 0, если оба прогона в пределах, 1 при провале, 2 при ошибке вызова
# или записи набора.
# Рассчитан на bash 3.2 и BSD-утилиты.
set -uo pipefail

USAGE="usage: $0 [--preset default|max|user] [--style waves|spectrum|minimal|pulse] [--island collapsed|expanded|banner] [--sample] <WaveFeels.app> [seconds]"

usage() {
    echo "$USAGE" >&2
    echo "run $0 --help for details" >&2
    exit 2
}

print_help() {
    cat <<EOF
$USAGE

Measures CPU and memory of a built WaveFeels.app in two runs (play with Demo/demo.wav,
silence with Demo/silence.wav) on settings from the com.wfeels.wavefeels.benchmark suite.
Quit WaveFeels first. Writes \$OUT/<prefix>.txt (default ci-out/cpu.txt) and prints it.

  --preset default  1.1 default look; play limit 15 %; report cpu.txt (default)
  --preset max      upper bound of every look slider; play limit 20 %; report cpu-max.txt
  --preset user     the owner's wf.* keys copied from com.wfeels.wavefeels, wf.paused forced
                    to 0; play limit 20 %; report cpu-user.txt
  --style STYLE     wave style written over the preset (also over the owner's settings with
                    --preset user): waves, spectrum, minimal or pulse; stored as JSON data in
                    wf.waveStyle, checked by "стиль STYLE" in the app's settings line; report
                    and sample files get the style suffix (cpu-max-pulse-expanded.txt); without
                    it the preset's own style is kept (waves for default and max)
  --island MODE     play run only, the island's state machine still drives it:
                      collapsed  the pointer never expands the island
                      expanded   held open as if hovered; checked by "остров: ... -> раскрыт"
                      banner     a fake track change every 6 s; checked by
                                 "баннер нового трека показан"; sets wf.showTrackBanner = 1
                    report and sample files get the mode suffix (cpu-user-expanded.txt)
  --sample          sample the stacks for 5 s (play: mid-window, silence: after the window)
  seconds           measuring window after a 5 s warm-up, at least 5 (default 30)
  -h, --help        this help

The report header has the applied settings and, from the app's last render log line of the
play run, frames/s and p50 (expanded bucket with --island expanded, collapsed otherwise).
Exit code: 0 within limits, 1 failure, 2 usage or settings error.
EOF
    exit 0
}

PRESET=default
STYLE=""
ISLAND=""
SAMPLE=0
APP_ARG=""
DURATION=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        -h | --help)
            print_help
            ;;
        --preset)
            [[ $# -ge 2 ]] || usage
            PRESET=$2
            shift 2
            ;;
        --style)
            [[ $# -ge 2 ]] || usage
            STYLE=$2
            shift 2
            ;;
        --island)
            [[ $# -ge 2 ]] || usage
            ISLAND=$2
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
    user)
        PLAY_LIMIT=20
        PREFIX=cpu-user
        ;;
    *)
        echo "cpu-probe: unknown preset $PRESET (expected default, max or user)" >&2
        usage
        ;;
esac

case "$STYLE" in
    "") ;;
    waves | spectrum | minimal | pulse)
        PREFIX="$PREFIX-$STYLE"
        ;;
    *)
        echo "cpu-probe: unknown style $STYLE (expected waves, spectrum, minimal or pulse)" >&2
        usage
        ;;
esac

case "$ISLAND" in
    "") ;;
    collapsed | expanded | banner)
        PREFIX="$PREFIX-$ISLAND"
        ;;
    *)
        echo "cpu-probe: unknown island mode $ISLAND (expected collapsed, expanded or banner)" >&2
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
# Настройки пользователя, из которых --preset user берет ключи wf.*.
USER_DOMAIN=com.wfeels.wavefeels

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
    local lines fill radius glow wings thickness amplitude flow
    if [[ $PRESET == user ]]; then
        copy_user_settings || return 1
    else
        if [[ $PRESET == max ]]; then
            lines=6 fill=1 radius=3 glow=1 wings=200 thickness=2 amplitude=2 flow=1
        else
            lines=3 fill=0 radius=1 glow=0.6 wings=64 thickness=1 amplitude=1 flow=0
        fi
        defaults delete "$SUITE" > /dev/null 2>&1
        defaults write "$SUITE" wf.lineCount -int "$lines" &&
            defaults write "$SUITE" wf.fill -float "$fill" &&
            defaults write "$SUITE" wf.glowRadius -float "$radius" &&
            defaults write "$SUITE" wf.glowIntensity -float "$glow" &&
            defaults write "$SUITE" wf.wingWidth -float "$wings" &&
            defaults write "$SUITE" wf.lineThickness -float "$thickness" &&
            defaults write "$SUITE" wf.waveAmplitude -float "$amplitude" &&
            defaults write "$SUITE" wf.colorFlow -float "$flow" &&
            defaults write "$SUITE" wf.beatPulse -bool true &&
            defaults write "$SUITE" wf.softPulse -bool true &&
            defaults write "$SUITE" wf.paused -bool false || return 1
    fi
    # Стиль волн: JSON-строка в кавычках как данные, так ее пишет AppSettings (JSONEncoder).
    if [[ -n $STYLE ]]; then
        defaults write "$SUITE" wf.waveStyle -data "$(printf '"%s"' "$STYLE" | xxd -p | tr -d '\n')" || return 1
    fi
    # Баннер нового трека может быть выключен у владельца, а режим banner мерит именно его.
    if [[ $ISLAND == banner ]]; then
        defaults write "$SUITE" wf.showTrackBanner -bool true || return 1
    fi
}

# --preset user: ключи wf.* из настроек пользователя в пустой набор замера. Домен выгружается
# (`defaults export`), переводится в XML (`plutil -convert xml1`), и из словаря верхнего уровня
# остаются только записи wf.*. plutil начинает запись верхнего уровня строкой «<таб><key>»;
# запись тянется до следующей такой строки или до «</dict>» без отступа, закрывающего словарь
# (многострочные значения и вложенные словари внутри; «<» в тексте значений экранируется).
# Заголовок до первой записи и хвост остаются как есть. Ключи с точкой нельзя адресовать через
# `plutil -extract` (точка там разделитель пути), поэтому фильтр по строкам. Затем
# `defaults import` и принудительно wf.paused = 0.
USER_KEYS=0
copy_user_settings() {
    local tab
    tab=$(printf '\t')
    if ! defaults export "$USER_DOMAIN" "$TMP/user.plist" > /dev/null 2>&1; then
        echo "cpu-probe: defaults export $USER_DOMAIN failed (no personal settings yet?)" >&2
        return 1
    fi
    plutil -convert xml1 -o "$TMP/user.xml" "$TMP/user.plist" || return 1
    awk -v tab="$tab" '
        index($0, tab "<key>") == 1 { entry = 1; keep = (index($0, tab "<key>wf.") == 1) }
        $0 == "</dict>" { entry = 0 }
        entry { if (keep) print; next }
        { print }
    ' "$TMP/user.xml" > "$TMP/user-wf.xml" || return 1
    if ! plutil -lint "$TMP/user-wf.xml" > /dev/null; then
        echo "cpu-probe: the wf.* keys filtered from $USER_DOMAIN do not form a valid plist" >&2
        return 1
    fi
    USER_KEYS=$(grep -c "^$tab<key>wf\." "$TMP/user-wf.xml")
    defaults delete "$SUITE" > /dev/null 2>&1
    defaults import "$SUITE" "$TMP/user-wf.xml" &&
        defaults write "$SUITE" wf.paused -bool false
}

if ! write_preset; then
    echo "cpu-probe: writing preset $PRESET into $SUITE failed" >&2
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

# Частота кадров и p50 из строки лога «отрисовка, <корзина>: ... | p50 16.7 мс | ... | 59.8
# кадров/с» (RenderPacingSummary.description); пусто, если строки нет или в ней нет данных.
render_summary() { # строка лога
    local fps p50
    fps=$(printf '%s\n' "$1" | sed -n 's/.* | \([0-9.]*\) кадров\/с$/\1/p')
    p50=$(printf '%s\n' "$1" | sed -n 's/.* | p50 \([0-9.]*\) мс | .*/\1/p')
    if [[ -n "$fps" && -n "$p50" ]]; then
        echo "$fps frames/s, p50 $p50 ms"
    fi
}

# Один прогон: имя, предел среднего в процентах, сравнение (max: не больше предела, below: строго
# меньше), каким должен быть остров (hidden; shown: показан; collapsed, expanded, banner: показан
# в режиме --island), когда снимать стеки (window: в середине окна, after: сразу после него),
# через сколько секунд приложение выходит само (--exit-after), остальные аргументы приложения.
probe() {
    local name=$1 limit=$2 compare=$3 expect_island=$4 sample_at=$5 exit_after=$6
    shift 6
    local log_start pid wd rc t0 c0 k0 t1 c1 k1 t c r prev_t prev_c sec
    local per_second="" max_sec=0 rss_first="" rss_last=0 rss_max=0 alive=1 sampled=0
    local average children verdict=ok reasons="" app_log="$TMP/$name.log" settings_line
    local bucket=collapsed bucket_log=свернутый render_line render

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
        if [[ -z "$APPLIED" ]]; then
            APPLIED=${settings_line#*"$SETTINGS_MARK"}
        fi
        # --style: приложение должно было прочитать стиль из набора (строка «стиль <стиль>,»).
        if [[ -n $STYLE && $settings_line != *"стиль $STYLE,"* ]]; then
            reasons="$reasons; app did not report style $STYLE (wf.waveStyle not applied, build before 1.2?)"
        fi
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
        if [[ $expect_island != hidden ]]; then
            reasons="$reasons; island never appeared, the measurement does not cover drawing"
        fi
    fi
    # Режим --island: раскрытие и баннер проверяются по строкам лога приложения.
    case "$expect_island" in
        expanded)
            if grep -q 'остров: .* -> раскрыт' "$app_log"; then
                report "island expanded: yes (--island expanded)"
            else
                report "island expanded: no (--island expanded)"
                reasons="$reasons; island never expanded with --island expanded"
            fi
            ;;
        collapsed | banner)
            if grep -q 'остров: .* -> раскрыт' "$app_log"; then
                report "island expanded: yes (--island $expect_island keeps it collapsed)"
                reasons="$reasons; island expanded although --island $expect_island keeps it collapsed"
            else
                report "island expanded: no (--island $expect_island)"
            fi
            ;;
    esac
    if [[ $expect_island == banner ]]; then
        if grep -q 'баннер нового трека показан' "$app_log"; then
            report "banner: shown (--island banner)"
        else
            report "banner: never shown (--island banner)"
            reasons="$reasons; track banner never appeared with --island banner"
        fi
    fi
    # Частота кадров: последняя строка корзины, которую рисует прогон. В тишине ничего не рисуется.
    if [[ $expect_island != hidden ]]; then
        if [[ $expect_island == expanded ]]; then
            bucket=expanded
            bucket_log=раскрытый
        fi
        render_line=$(grep -F "отрисовка, $bucket_log: " "$app_log" | tail -n 1)
        render=$(render_summary "$render_line")
        report "render ($bucket): ${render:-not reported}"
        if [[ $name == play && -n "$render" ]]; then
            RENDER="$bucket, play run: $render"
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
if [[ $PRESET == user ]]; then
    report "user settings: $USER_KEYS wf.* keys copied from $USER_DOMAIN, wf.paused forced to 0"
fi
report "style: ${STYLE:-not forced} (--style)"
report "island: ${ISLAND:-not forced} (--island, play run only)"
report "method: cumulative CPU time from ps over a ${DURATION} s window after ${WARMUP} s warm-up, % of one core"
report "machine: $(sysctl -n machdep.cpu.brand_string 2>/dev/null || uname -m), $(sysctl -n hw.ncpu 2>/dev/null || echo '?') cores, macOS $(sw_vers -productVersion 2>/dev/null || echo '?')"
report ""
report "defaults read $SUITE:"
report "$(defaults read "$SUITE" 2>&1)"
# Строку заменяет настоящая строка приложения из первого прогона, где она нашлась (обычно play).
APPLIED_PLACEHOLDER="applied settings: not reported by the app"
APPLIED=""
report ""
report "$APPLIED_PLACEHOLDER"
# Частота кадров и p50 из последней строки отрисовки прогона play (render_summary).
RENDER_PLACEHOLDER="render: not reported by the app"
RENDER=""
report "$RENDER_PLACEHOLDER"

EXIT_AFTER=$((DURATION + 10))
# С --sample в тишине стеки снимаются после окна, на это приложению нужны лишние 10 с.
SILENCE_EXIT_AFTER=$EXIT_AFTER
if [[ $SAMPLE -eq 1 ]]; then
    SILENCE_EXIT_AFTER=$((EXIT_AFTER + 10))
fi
# --island только в play: прогон silence ждет скрытый остров.
PLAY_ARGS=(--demo "$DEMO_DIR/demo.wav" --fake-notch)
if [[ -n "$ISLAND" ]]; then
    PLAY_ARGS+=(--island "$ISLAND")
fi
probe play "$PLAY_LIMIT" max "${ISLAND:-shown}" window "$EXIT_AFTER" "${PLAY_ARGS[@]}"
probe silence "$SILENCE_LIMIT" below hidden after "$SILENCE_EXIT_AFTER" --demo "$DEMO_DIR/silence.wav" --fake-notch --no-capture

# Шапка отчета уже записана, поэтому строка подставляется в файл на место заглушки (через
# ENVIRON, а не -v: awk -v разбирает обратные косые черты).
replace_header_line() { # заглушка, строка
    PLACEHOLDER="$1" LINE="$2" \
        awk '!done && $0 == ENVIRON["PLACEHOLDER"] { print ENVIRON["LINE"]; done = 1; next } { print }' \
        "$REPORT" > "$TMP/report.txt" && cat "$TMP/report.txt" > "$REPORT"
}

# В stdout строки шапки идут перед итогом.
if [[ -n "$APPLIED" || -n "$RENDER" ]]; then
    echo ""
fi
if [[ -n "$APPLIED" ]]; then
    replace_header_line "$APPLIED_PLACEHOLDER" "applied settings: $APPLIED"
    echo "applied settings: $APPLIED"
fi
if [[ -n "$RENDER" ]]; then
    replace_header_line "$RENDER_PLACEHOLDER" "render: $RENDER"
    echo "render: $RENDER"
fi

report ""
if [[ $FAILED -eq 0 ]]; then
    report "result: success"
    exit 0
fi
report "result: failure"
exit 1
