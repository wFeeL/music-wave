#!/usr/bin/env bash
# Поиск и импорт ключа подписи WaveFeels. Файл подключается через source, сам не запускается.
# Ключ (wavefeels-signing.p12 + password.txt) в репозитории не хранится. Порядок поиска:
#   1. $WAVEFEELS_SIGNING_DIR
#   2. ~/Library/Application Support/WaveFeels/signing
#   3. signing/ в репозитории (старые копии, где ключ еще лежит рядом с кодом)
# WAVEFEELS_REPO_SIGNING_DIR подменяет третий каталог, это нужно только тесту.
# Рассчитан на bash 3.2 и BSD-утилиты. Пароль нигде не печатается.

SIGNING_P12_NAME=wavefeels-signing.p12
SIGNING_PASSWORD_NAME=password.txt

# Каталог с ключом в Application Support, куда ключ импортируется.
signing_app_support_dir() {
    printf '%s\n' "$HOME/Library/Application Support/WaveFeels/signing"
}

signing_repo_dir() {
    if [[ -n "${WAVEFEELS_REPO_SIGNING_DIR:-}" ]]; then
        printf '%s\n' "$WAVEFEELS_REPO_SIGNING_DIR"
        return 0
    fi
    local here
    here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
    printf '%s\n' "$here/signing"
}

# 0, если в каталоге $1 есть и сертификат, и пароль.
signing_dir_has_pair() {
    [[ -n "${1:-}" && -f "$1/$SIGNING_P12_NAME" && -f "$1/$SIGNING_PASSWORD_NAME" ]]
}

# Предупреждает, если в каталоге $1 лежит только один из двух файлов.
warn_partial_pair() {
    local dir=$1
    [[ -d "$dir" ]] || return 0
    if [[ -f "$dir/$SIGNING_P12_NAME" && ! -f "$dir/$SIGNING_PASSWORD_NAME" ]]; then
        echo "ВНИМАНИЕ: в «$dir» нет файла $SIGNING_PASSWORD_NAME, эта папка пропущена." >&2
    elif [[ ! -f "$dir/$SIGNING_P12_NAME" && -f "$dir/$SIGNING_PASSWORD_NAME" ]]; then
        echo "ВНИМАНИЕ: в «$dir» нет файла $SIGNING_P12_NAME, эта папка пропущена." >&2
    fi
    return 0
}

# Печатает каталог с парой файлов или возвращает 1.
find_signing_dir() {
    local candidate
    if [[ -n "${WAVEFEELS_SIGNING_DIR:-}" ]]; then
        if signing_dir_has_pair "$WAVEFEELS_SIGNING_DIR"; then
            printf '%s\n' "$WAVEFEELS_SIGNING_DIR"
            return 0
        fi
        echo "WAVEFEELS_SIGNING_DIR=$WAVEFEELS_SIGNING_DIR: нет пары файлов, ищу дальше." >&2
    fi
    candidate=$(signing_app_support_dir)
    if signing_dir_has_pair "$candidate"; then
        printf '%s\n' "$candidate"
        return 0
    fi
    warn_partial_pair "$candidate"
    candidate=$(signing_repo_dir)
    if signing_dir_has_pair "$candidate"; then
        printf '%s\n' "$candidate"
        return 0
    fi
    return 1
}

# Копирует пару файлов из $1 в Application Support: файлы 600, каталог 700.
# 1, если в $1 нет одного из файлов.
import_signing_dir() {
    local src=${1:-} dest
    if ! signing_dir_has_pair "$src"; then
        echo "В папке «$src» нет двух файлов: $SIGNING_P12_NAME и $SIGNING_PASSWORD_NAME." >&2
        return 1
    fi
    dest=$(signing_app_support_dir)
    mkdir -p "$dest" || return 1
    chmod 700 "$dest" || return 1
    # Тот же каталог: копировать нечего, права все равно подтягиваются.
    if [[ "$(cd "$src" && pwd -P)" != "$(cd "$dest" && pwd -P)" ]]; then
        (
            umask 077
            cp "$src/$SIGNING_P12_NAME" "$dest/$SIGNING_P12_NAME" &&
                cp "$src/$SIGNING_PASSWORD_NAME" "$dest/$SIGNING_PASSWORD_NAME"
        ) || return 1
    fi
    chmod 600 "$dest/$SIGNING_P12_NAME" "$dest/$SIGNING_PASSWORD_NAME" || return 1
    return 0
}

# Хэш без пробелов, табуляций, переводов строк, двоеточий и обертки H"...", строчными буквами.
normalize_hash() {
    printf '%s' "$1" | tr -d ' \t\r\n:' | tr '[:upper:]' '[:lower:]' | sed -E 's/^h"(.*)"$/\1/'
}

# SHA-1 листового сертификата из p12 в каталоге $1 (40 символов, строчные). Код 1, если
# openssl не смог прочитать файл: нет openssl, другой формат шифрования, неверный пароль.
# Сначала без -legacy (LibreSSL в macOS), потом с ним (OpenSSL 3 и старые p12).
signing_leaf_hash() {
    local dir=$1 pw out legacy
    if ! command -v openssl > /dev/null 2>&1 || ! signing_dir_has_pair "$dir"; then
        return 1
    fi
    pw=$(tr -d '\r\n' < "$dir/$SIGNING_PASSWORD_NAME")
    for legacy in "" "-legacy"; do
        # shellcheck disable=SC2086 # $legacy пустой или один флаг
        if out=$(WF_P12_PW=$pw openssl pkcs12 $legacy -in "$dir/$SIGNING_P12_NAME" -passin env:WF_P12_PW \
            -nokeys -clcerts 2> /dev/null | openssl x509 -noout -fingerprint -sha1 2> /dev/null); then
            out=$(normalize_hash "${out#*=}")
            if [[ "$out" =~ ^[0-9a-f]{40}$ ]]; then
                printf '%s\n' "$out"
                return 0
            fi
        fi
    done
    return 1
}

# Сверяет хэш листа из p12 в каталоге $1 с ожидаемым $2.
# 0 совпал, 1 не совпал, 2 прочитать p12 через openssl не удалось.
signing_leaf_matches() {
    local actual expected
    if ! actual=$(signing_leaf_hash "$1"); then
        return 2
    fi
    expected=$(normalize_hash "$2")
    [[ "$actual" == "$expected" ]] && return 0
    return 1
}

# Ищет в ~/Downloads/music-wave-develop*/signing/ (в том числе «music-wave-develop 2») старую
# распакованную копию с нужным ключом и печатает ее каталог. Сначала берется копия, чей хэш
# совпал с ожидаемым $1. Копии с другим хэшем пропускаются. Если подтвердить не удалось
# нигде, но есть копия с нечитаемым через openssl p12, берется первая такая: настоящая
# проверка идет после подписи в sign.sh. Код 1, если ничего не найдено.
find_downloads_signing_dir() {
    local expected=$1 dir rc unverified=""
    for dir in "$HOME"/Downloads/music-wave-develop*/signing; do
        if ! signing_dir_has_pair "$dir"; then
            continue
        fi
        rc=0
        signing_leaf_matches "$dir" "$expected" || rc=$?
        if [[ $rc -eq 0 ]]; then
            printf '%s\n' "$dir"
            return 0
        fi
        if [[ $rc -eq 2 && -z "$unverified" ]]; then
            unverified=$dir
        fi
    done
    if [[ -n "$unverified" ]]; then
        printf '%s\n' "$unverified"
        return 0
    fi
    return 1
}
