#!/usr/bin/env bash
# Проверяет scripts/signing-source.sh: порядок поиска ключа подписи, импорт и сверку хэша.
# Работает на Linux и macOS, во временном HOME, без сети и без настоящего ключа.
# Использование: bash scripts/test-signing-source.sh
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

FAILS=0
PASSES=0

check() { # описание, команда...
    local name=$1
    shift
    if "$@"; then
        PASSES=$((PASSES + 1))
        echo "ok   $name"
    else
        FAILS=$((FAILS + 1))
        echo "FAIL $name"
    fi
}

eq() { [[ "$1" == "$2" ]]; }

mkpair() { # каталог
    mkdir -p "$1"
    printf 'fake-p12' > "$1/wavefeels-signing.p12"
    printf 'fake-password\n' > "$1/password.txt"
}

mode_of() { # путь
    stat -c '%a' "$1" 2> /dev/null || stat -f '%Lp' "$1"
}

if [[ ! -f "$SCRIPT_DIR/signing-source.sh" ]]; then
    echo "FAIL нет scripts/signing-source.sh"
    exit 1
fi

export HOME="$TMP/home"
mkdir -p "$HOME"
APP_DIR="$HOME/Library/Application Support/WaveFeels/signing"
ENV_DIR="$TMP/env-signing"
LEGACY_DIR="$TMP/repo-signing"
unset WAVEFEELS_SIGNING_DIR SIGNING_EXPECTED_LEAF || true
export WAVEFEELS_REPO_SIGNING_DIR="$LEGACY_DIR"

# shellcheck source=scripts/signing-source.sh
source "$SCRIPT_DIR/signing-source.sh"

# --- find_signing_dir ---

if find_signing_dir > /dev/null 2>&1; then rc=0; else rc=$?; fi
check "нигде нет ключа: код 1 (find_signing_dir)" eq "$rc" 1

mkpair "$LEGACY_DIR"
check "остался только каталог репозитория" eq "$(find_signing_dir)" "$LEGACY_DIR"

mkpair "$APP_DIR"
check "Application Support раньше каталога репозитория" eq "$(find_signing_dir)" "$APP_DIR"

mkpair "$ENV_DIR"
export WAVEFEELS_SIGNING_DIR="$ENV_DIR"
check "WAVEFEELS_SIGNING_DIR раньше всех" eq "$(find_signing_dir)" "$ENV_DIR"

export WAVEFEELS_SIGNING_DIR=""
check "пустая переменная пропускается" eq "$(find_signing_dir)" "$APP_DIR"

export WAVEFEELS_SIGNING_DIR="$TMP/no-such-dir"
check "переменная на несуществующий каталог пропускается" eq "$(find_signing_dir 2> /dev/null)" "$APP_DIR"
unset WAVEFEELS_SIGNING_DIR

rm "$APP_DIR/password.txt"
check "неполная пара в Application Support пропускается" eq "$(find_signing_dir 2> /dev/null)" "$LEGACY_DIR"
WARN=$(find_signing_dir 2>&1 > /dev/null)
check "неполная пара в Application Support: предупреждение с именем файла" \
    eq "$([[ "$WARN" == *"нет файла password.txt"* ]] && echo yes)" yes
rm -rf "$HOME/Library"

# --- signing_expected_leaf ---

OWNER_LEAF=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
OWN_LEAF=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
rm -f "$LEGACY_DIR/expected-leaf.txt"
if signing_expected_leaf > /dev/null 2>&1; then rc=0; else rc=$?; fi
check "ожидаемого хэша нет нигде: код 1" eq "$rc" 1
printf '%s\n' "$OWNER_LEAF" > "$LEGACY_DIR/expected-leaf.txt"
check "ожидаемый хэш из signing/ репозитория" eq "$(signing_expected_leaf)" "$OWNER_LEAF"
mkdir -p "$APP_DIR"
# Так файл пишут команды из README: отпечаток openssl с двоеточиями и заглавными.
printf 'BB:BB:BB:BB:BB:BB:BB:BB:BB:BB:BB:BB:BB:BB:BB:BB:BB:BB:BB:BB\n' > "$APP_DIR/expected-leaf.txt"
check "свой хэш в Application Support важнее репозитория" eq "$(signing_expected_leaf)" "$OWN_LEAF"
check "переменная SIGNING_EXPECTED_LEAF важнее файлов" \
    eq "$(SIGNING_EXPECTED_LEAF="H\"CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC\"" signing_expected_leaf)" \
    cccccccccccccccccccccccccccccccccccccccc
rm -rf "$HOME/Library" "$LEGACY_DIR/expected-leaf.txt"

# --- import_signing_dir ---

SRC="$TMP/old copy/signing"
mkpair "$SRC"
chmod 644 "$SRC/wavefeels-signing.p12" "$SRC/password.txt"
import_signing_dir "$SRC" > /dev/null
check "импорт: p12 скопирован" eq "$(cat "$APP_DIR/wavefeels-signing.p12")" "fake-p12"
check "импорт: пароль скопирован" eq "$(cat "$APP_DIR/password.txt")" "fake-password"
check "импорт: p12 с правами 600" eq "$(mode_of "$APP_DIR/wavefeels-signing.p12")" 600
check "импорт: пароль с правами 600" eq "$(mode_of "$APP_DIR/password.txt")" 600
check "импорт: каталог с правами 700" eq "$(mode_of "$APP_DIR")" 700
check "после импорта ключ находится" eq "$(find_signing_dir)" "$APP_DIR"
if import_signing_dir "$APP_DIR" > /dev/null 2>&1; then rc=0; else rc=$?; fi
check "импорт из самого себя не ломает файлы" eq "$rc.$(cat "$APP_DIR/password.txt")" "0.fake-password"

EMPTY="$TMP/empty/signing"
mkdir -p "$EMPTY"
printf 'x' > "$EMPTY/wavefeels-signing.p12"
rm -rf "$HOME/Library"
if import_signing_dir "$EMPTY" > /dev/null 2>&1; then rc=0; else rc=$?; fi
check "импорт без password.txt отказан" eq "$rc" 1
check "после отказа ничего не скопировано" test ! -e "$APP_DIR/wavefeels-signing.p12"

rm "$EMPTY/wavefeels-signing.p12"
printf 'x' > "$EMPTY/password.txt"
if import_signing_dir "$EMPTY" > /dev/null 2>&1; then rc=0; else rc=$?; fi
check "импорт без p12 отказан" eq "$rc" 1

if import_signing_dir "$TMP/nope" > /dev/null 2>&1; then rc=0; else rc=$?; fi
check "импорт из несуществующего каталога отказан" eq "$rc" 1

# --- хэш листового сертификата ---

if command -v openssl > /dev/null 2>&1; then
    REAL="$TMP/real/signing"
    mkdir -p "$REAL"
    openssl req -x509 -newkey rsa:2048 -nodes -days 2 -subj "/CN=WaveFeels Test" \
        -keyout "$TMP/k.pem" -out "$TMP/c.pem" > /dev/null 2>&1
    printf 'pw-for-test\r\n' > "$REAL/password.txt"
    openssl pkcs12 -export -inkey "$TMP/k.pem" -in "$TMP/c.pem" -passout pass:pw-for-test \
        -out "$REAL/wavefeels-signing.p12" > /dev/null 2>&1
    WANT=$(openssl x509 -in "$TMP/c.pem" -noout -fingerprint -sha1 | sed 's/.*=//; s/://g' | tr 'A-F' 'a-f')
    check "хэш листа совпадает с openssl x509" eq "$(signing_leaf_hash "$REAL")" "$WANT"
    check "сверка: совпало (с обертью и заглавными)" signing_leaf_matches "$REAL" "H\"$(printf '%s' "$WANT" | tr 'a-f' 'A-F')\""
    if signing_leaf_matches "$REAL" "0000000000000000000000000000000000000000"; then rc=0; else rc=$?; fi
    check "сверка: другой хэш дает код 1" eq "$rc" 1
    printf 'garbage' > "$REAL/wavefeels-signing.p12"
    if signing_leaf_matches "$REAL" "$WANT"; then rc=0; else rc=$?; fi
    check "сверка: нечитаемый p12 дает код 2" eq "$rc" 2

    # --- поиск в Загрузках ---
    mkdir -p "$TMP/real2/signing"
    openssl pkcs12 -export -inkey "$TMP/k.pem" -in "$TMP/c.pem" -passout pass:pw-for-test \
        -out "$TMP/real2/signing/wavefeels-signing.p12" > /dev/null 2>&1
    cp "$REAL/password.txt" "$TMP/real2/signing/password.txt"
    rm -rf "$HOME/Downloads"
    mkdir -p "$HOME/Downloads/music-wave-develop/signing"
    printf 'x' > "$HOME/Downloads/music-wave-develop/signing/wavefeels-signing.p12"
    printf 'x\n' > "$HOME/Downloads/music-wave-develop/signing/password.txt"
    mkdir -p "$HOME/Downloads/music-wave-develop 2"
    cp -R "$TMP/real2/signing" "$HOME/Downloads/music-wave-develop 2/signing"
    check "Загрузки: подтвержденная копия с пробелом в имени важнее нечитаемой" \
        eq "$(find_downloads_signing_dir "$WANT")" "$HOME/Downloads/music-wave-develop 2/signing"
    check "Загрузки: нечитаемая копия берется, если подтвержденной нет" \
        eq "$(find_downloads_signing_dir "1111111111111111111111111111111111111111")" "$HOME/Downloads/music-wave-develop/signing"
    rm -rf "$HOME/Downloads/music-wave-develop"
    if find_downloads_signing_dir "1111111111111111111111111111111111111111" > /dev/null 2>&1; then rc=0; else rc=$?; fi
    check "Загрузки: читаемая копия с другим хэшем пропускается, код 1" eq "$rc" 1

    # --- make-signing-key.sh ---
    rm -rf "$HOME/Library" "$HOME/Downloads" "$LEGACY_DIR"
    KEY_OUT=$(bash "$SCRIPT_DIR/make-signing-key.sh" 2>&1) && rc=0 || rc=$?
    check "make-signing-key: ключ создан, код 0" eq "$rc" 0
    check "make-signing-key: пара найдена в Application Support" eq "$(find_signing_dir)" "$APP_DIR"
    check "make-signing-key: хэш p12 совпадает с expected-leaf.txt" \
        eq "$(signing_leaf_hash "$APP_DIR")" "$(signing_expected_leaf)"
    check "make-signing-key: p12 с правами 600" eq "$(mode_of "$APP_DIR/wavefeels-signing.p12")" 600
    check "make-signing-key: каталог с правами 700" eq "$(mode_of "$APP_DIR")" 700
    BEFORE=$(cat "$APP_DIR/expected-leaf.txt")
    KEY_OUT=$(bash "$SCRIPT_DIR/make-signing-key.sh" 2>&1) && rc=0 || rc=$?
    check "make-signing-key: повторный запуск ключ не меняет" eq "$rc.$(cat "$APP_DIR/expected-leaf.txt")" "0.$BEFORE"
    check "make-signing-key: повторный запуск говорит, что ключ есть" \
        eq "$([[ "$KEY_OUT" == *"уже есть"* ]] && echo yes)" yes
    rm -rf "$HOME/Library"
    mkdir -p "$HOME/Downloads/music-wave-develop 2"
    cp -R "$TMP/real2/signing" "$HOME/Downloads/music-wave-develop 2/signing"
    KEY_OUT=$(bash "$SCRIPT_DIR/make-signing-key.sh" 2>&1) && rc=0 || rc=$?
    check "make-signing-key: старая копия в Загрузках, код 1 и ничего не создано" \
        eq "$rc.$([[ -e "$APP_DIR" ]] && echo made || echo none)" "1.none"
    rm -rf "$HOME/Library" "$HOME/Downloads"
else
    echo "skip проверки хэша: нет openssl"
fi

rm -rf "$HOME/Downloads"
if find_downloads_signing_dir "$(printf '0%.0s' $(seq 1 40))" > /dev/null 2>&1; then rc=0; else rc=$?; fi
check "Загрузки: пусто, код 1" eq "$rc" 1

# --- sign.sh в CI без сертификата ---

rm -rf "$HOME/Library"
mkdir -p "$TMP/fake.app"
CI_OUT=$(env -u SIGNING_P12_BASE64 -u SIGNING_P12_PASSWORD GITHUB_ACTIONS=true WAVEFEELS_REPO_SIGNING_DIR="$TMP/none" \
    bash "$SCRIPT_DIR/sign.sh" "$TMP/fake.app" 2>&1) && rc=0 || rc=$?
check "sign.sh в CI без ключа: код 1" eq "$rc" 1
check "sign.sh в CI без ключа: сообщение про секреты" eq "$([[ "$CI_OUT" == *SIGNING_P12_BASE64* ]] && echo yes)" yes
check "sign.sh в CI без ключа: ad-hoc не запускался" eq "$([[ "$CI_OUT" == *"signing ad-hoc"* ]] && echo yes || echo no)" no

echo
echo "прошло: $PASSES, упало: $FAILS"
[[ $FAILS -eq 0 ]]
