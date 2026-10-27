#!/usr/bin/env bash
# Оформление вывода скриптов WaveFeels: шаги, отметки, итоговый блок, строка прогресса.
# Файл подключается через source, сам не запускается. ui_init вызывать до того, как stdout
# уйдет в tee: цвет и строка прогресса включаются, только если вывод идет в терминал.
# NO_COLOR=1 выключает цвет. Рассчитан на bash 3.2 и BSD-утилиты.

UI_TTY=0
UI_STEP=0
UI_STEPS=0
C_RESET="" C_BOLD="" C_DIM="" C_RED="" C_GREEN="" C_YELLOW="" C_CYAN=""

ui_init() {
    if [[ -t 1 && "${TERM:-}" != dumb ]] && { : > /dev/tty; } 2> /dev/null; then
        UI_TTY=1
    fi
    if [[ $UI_TTY -eq 1 && -z "${NO_COLOR:-}" ]]; then
        C_RESET=$'\033[0m'
        C_BOLD=$'\033[1m'
        C_DIM=$'\033[2m'
        C_RED=$'\033[31m'
        C_GREEN=$'\033[32m'
        C_YELLOW=$'\033[33m'
        C_CYAN=$'\033[36m'
    fi
}

# Убирает цветовые коды из потока: так пишется лог. Построчный буфер (-l в BSD sed, -u в GNU),
# иначе строки шагов попадут в лог позже строк, которые ui_progress_filter пишет напрямую.
ui_strip() {
    local flag=-l
    if ! echo | sed -l '' > /dev/null 2>&1; then
        flag=-u
    fi
    sed $flag "s/$(printf '\033')\[[0-9;]*m//g"
}

ui_rule() {
    printf '%s━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━%s\n' "$C_CYAN" "$C_RESET"
}

ui_header() { # заголовок
    echo
    ui_rule
    printf '  %s%s%s\n' "$C_BOLD" "$1" "$C_RESET"
    ui_rule
}

ui_step() { # название шага
    UI_STEP=$((UI_STEP + 1))
    if [[ $UI_STEPS -gt 0 ]]; then
        printf '\n%s[%d/%d]%s %s%s%s\n' "$C_CYAN$C_BOLD" "$UI_STEP" "$UI_STEPS" "$C_RESET" "$C_BOLD" "$1" "$C_RESET"
    else
        printf '\n%s==>%s %s%s%s\n' "$C_CYAN$C_BOLD" "$C_RESET" "$C_BOLD" "$1" "$C_RESET"
    fi
}

ui_sub() { printf '  %s▸%s %s\n' "$C_CYAN" "$C_RESET" "$*"; }
ui_info() { printf '    %s%s%s\n' "$C_DIM" "$*" "$C_RESET"; }
ui_ok() { printf '  %s✓%s %s\n' "$C_GREEN" "$C_RESET" "$*"; }
ui_warn() { printf '\n  %s⚠ ВНИМАНИЕ:%s %s\n' "$C_YELLOW$C_BOLD" "$C_RESET" "$*"; }
ui_error() { printf '\n  %s✗ ОШИБКА:%s %s\n' "$C_RED$C_BOLD" "$C_RESET" "$*"; }

# Длительность в секундах словами: «45 с», «3 мин 12 с».
ui_duration() {
    local s=$1
    if [[ $s -ge 60 ]]; then
        printf '%d мин %d с' $((s / 60)) $((s % 60))
    else
        printf '%d с' "$s"
    fi
}

# Читает вывод swift build из stdin. Все строки дописывает в файлы-аргументы, а в терминал
# (/dev/tty, мимо лога) рисует одну строку: шкалу по «[n/N]» или текущее действие
# (Fetching, Computing и т. п.). Без терминала печатает строки как есть.
ui_progress_filter() { # файл...
    local line f done=0 total=0 pct=0 width cols filled bar i text
    local pattern='^\[([0-9]+)/([0-9]+)\] (.*)$'
    if [[ $UI_TTY -ne 1 ]]; then
        tee -a "$@"
        return 0
    fi
    cols=$(stty size < /dev/tty 2> /dev/null | awk '{print $2}')
    [[ "$cols" =~ ^[0-9]+$ && $cols -ge 40 ]] || cols=80
    width=24
    while IFS= read -r line || [[ -n "$line" ]]; do
        for f in "$@"; do
            printf '%s\n' "$line" >> "$f"
        done
        if [[ "$line" =~ $pattern ]]; then
            done=${BASH_REMATCH[1]}
            total=${BASH_REMATCH[2]}
            text=${BASH_REMATCH[3]}
            [[ $total -gt 0 ]] || total=1
            pct=$((done * 100 / total))
            filled=$((done * width / total))
            bar=""
            for ((i = 0; i < width; i++)); do
                if [[ $i -lt $filled ]]; then bar="${bar}█"; else bar="${bar}░"; fi
            done
            printf -v text '%3d%%  %d/%d  %s' "$pct" "$done" "$total" "$text"
            text=${text:0:$((cols - width - 8))}
            printf '\r\033[K  %s%s%s %s' "$C_CYAN" "$bar" "$C_RESET" "$text" > /dev/tty
        elif [[ -n "$line" ]]; then
            text=${line:0:$((cols - 6))}
            printf '\r\033[K  %s▸ %s%s' "$C_DIM" "$text" "$C_RESET" > /dev/tty
        fi
    done
    printf '\r\033[K' > /dev/tty
}

# Печатает строки с ошибками из вывода сборки (до 25), а если их нет, последние 25 строк.
ui_show_errors() { # файл
    local errors
    errors=$(grep -E '(error|fatal error):' "$1" | head -n 25 || true)
    if [[ -z "$errors" ]]; then
        errors=$(tail -n 25 "$1")
    fi
    printf '\n  %sПоследние ошибки сборки:%s\n' "$C_BOLD" "$C_RESET"
    printf '%s\n' "$errors" | sed 's/^/    /'
}
