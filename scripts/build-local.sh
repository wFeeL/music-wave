#!/usr/bin/env bash
# Собирает и подписывает WaveFeels на маке владельца, без GitHub Actions.
# Использование: scripts/build-local.sh [--test] [--install] [--version X.Y.Z] [--signing-dir ПАПКА]
#   --test     перед сборкой swift build --build-tests и swift test --skip-build;
#   --install  закрыть запущенный WaveFeels, заменить /Applications/WaveFeels.app и открыть его;
#   --signing-dir  папка с wavefeels-signing.p12 и password.txt: ключ копируется в
#              ~/Library/Application Support/WaveFeels/signing, дальше он берется оттуда;
#   --version  версия приложения, иначе самый новый тег v* (без v и суффикса, не ниже 1.1.0),
#              иначе 1.1.0. Номер сборки: date +%Y%m%d%H.
# Цепочка та же, что в ci-mac.sh: swift build -c release, адаптер, bundle.sh, sign.sh.
# Адаптер Now Playing: cmake есть, тогда build-adapter.sh; не вышло, части копируются из
# установленного /Applications/WaveFeels.app в dist/adapter-local; нет и их, сборка без
# Now Playing с предупреждением.
# Рассчитан на одни Command Line Tools: без actool иконка остается в .icns (RELEASE не задается),
# если swift test не находит фреймворк тестов, тесты пропускаются с подсказкой.
# git не обязателен: из архива GitHub (Download ZIP) без .git версия будет 1.1.0.
# Подпись: sign.sh с сертификатом во временной связке ключей; после выхода список связок
# ключей пользователя проверяется еще раз, даже если сборку прервали. Ключ в git не хранится,
# его ищет find_signing_dir (scripts/signing-source.sh). Если ключа нигде нет, а в
# ~/Downloads/music-wave-develop*/signing/ лежит старая копия с тем же хэшем сертификата, она
# импортируется. Иначе скрипт останавливается до сборки: подпись ad-hoc не используется.
# Весь вывод дублируется в dist/build-local.log. Скрипт рассчитан на bash 3.2 и BSD-утилиты.
set -euo pipefail

START_DIR=$PWD
cd "$(dirname "$0")/.."
ROOT=$PWD
# shellcheck source=scripts/signing-source.sh
source scripts/signing-source.sh

MIN_VERSION=1.1.0
APP="$ROOT/dist/WaveFeels.app"
INSTALLED=/Applications/WaveFeels.app

usage() {
    cat <<'EOF'
Использование: bash scripts/build-local.sh [--test] [--install] [--version X.Y.Z]
                                           [--signing-dir ПАПКА]

Собирает WaveFeels на этом маке и подписывает тем же сертификатом, что и
сборки из релизов, поэтому разрешение на запись звука сохраняется.

  --test            сначала прогнать тесты (с одними Command Line Tools
                    тесты могут не запуститься, тогда они пропускаются)
  --install         заменить WaveFeels в «Программах» новой сборкой и открыть
  --version X.Y.Z   версия приложения, по умолчанию из последнего тега v*,
                    но не ниже 1.1.0; без git 1.1.0
  --signing-dir ПАПКА
                    папка с wavefeels-signing.p12 и password.txt, например
                    ~/Downloads/music-wave-develop/signing. Ключ копируется в
                    «~/Library/Application Support/WaveFeels/signing», это нужно
                    один раз, дальше он берется оттуда
  -h, --help        показать эту справку

Нужны Command Line Tools: xcode-select --install.
Название и обложку трека дает адаптер Now Playing. Он собирается, если есть
cmake (brew install cmake), иначе берется из WaveFeels 0.9.0 или новее
в «Программах».

Результат: dist/WaveFeels.app. Полный вывод: dist/build-local.log.
EOF
}

RUN_TESTS=0
INSTALL=0
OPENED=0
VERSION=""
SIGNING_DIR_ARG=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --test) RUN_TESTS=1 ;;
        --install) INSTALL=1 ;;
        --version)
            if [[ $# -lt 2 ]]; then
                echo "После --version нужна версия, например --version 1.1.0" >&2
                exit 2
            fi
            VERSION=$2
            shift
            ;;
        --version=*) VERSION=${1#--version=} ;;
        --signing-dir)
            if [[ $# -lt 2 ]]; then
                echo "После --signing-dir нужна папка с ключом, например --signing-dir ~/Downloads/music-wave-develop/signing" >&2
                exit 2
            fi
            SIGNING_DIR_ARG=$2
            shift
            ;;
        --signing-dir=*) SIGNING_DIR_ARG=${1#--signing-dir=} ;;
        -h | --help)
            usage
            exit 0
            ;;
        *)
            echo "Неизвестный параметр: $1" >&2
            echo >&2
            usage >&2
            exit 2
            ;;
    esac
    shift
done

if [[ -n "$SIGNING_DIR_ARG" ]]; then
    # Тильда в кавычках не раскрывается, относительный путь считается от папки запуска.
    if [[ "$SIGNING_DIR_ARG" == "~" || "$SIGNING_DIR_ARG" == "~/"* ]]; then
        SIGNING_DIR_ARG="$HOME${SIGNING_DIR_ARG:1}"
    elif [[ "$SIGNING_DIR_ARG" != /* ]]; then
        SIGNING_DIR_ARG="$START_DIR/$SIGNING_DIR_ARG"
    fi
    # Можно указать и папку, внутри которой лежит signing/.
    if ! signing_dir_has_pair "$SIGNING_DIR_ARG" && signing_dir_has_pair "$SIGNING_DIR_ARG/signing"; then
        SIGNING_DIR_ARG="$SIGNING_DIR_ARG/signing"
    fi
    if ! signing_dir_has_pair "$SIGNING_DIR_ARG"; then
        echo "В папке «$SIGNING_DIR_ARG» нет двух файлов: wavefeels-signing.p12 и password.txt." >&2
        exit 2
    fi
fi

if [[ -n "$VERSION" && ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "Версия должна выглядеть как 1.1.0, получено: $VERSION" >&2
    exit 2
fi

if [[ "$(uname -s)" != Darwin ]]; then
    echo "WaveFeels собирается только на маке с Apple Silicon." >&2
    exit 1
fi
if [[ "$(uname -m)" != arm64 ]]; then
    if [[ "$(sysctl -n sysctl.proc_translated 2>/dev/null || true)" == 1 ]]; then
        echo "Терминал запущен через Rosetta. Закройте его, в Finder выберите Терминал," >&2
        echo "«Файл», «Свойства», снимите «Открывать в Rosetta» и запустите скрипт снова." >&2
    else
        echo "WaveFeels собирается только на маке с Apple Silicon." >&2
    fi
    exit 1
fi
if [[ $EUID -eq 0 ]]; then
    echo "Запускайте скрипт без sudo: bash scripts/build-local.sh" >&2
    exit 1
fi
MACOS_VERSION=$(sw_vers -productVersion)
if [[ ${MACOS_VERSION%%.*} -lt 26 ]]; then
    echo "WaveFeels работает на macOS 26 или новее, здесь macOS $MACOS_VERSION." >&2
    exit 1
fi

# Переменные CI здесь не нужны. С RELEASE bundle.sh падал бы без компилятора иконок (actool).
unset RELEASE ICON_SNAPSHOT_DIR RUNNER_TEMP ADAPTER_DIR

mkdir -p dist
LOG="$ROOT/dist/build-local.log"
: > "$LOG"
# tee не реагирует на Ctrl-C, иначе сообщения при прерывании уже некуда писать.
exec > >(
    trap '' INT TERM
    exec tee -a "$LOG"
) 2>&1

WORK=$(mktemp -d)
STEP="проверка инструментов"
WARNINGS=""
SAVED_KEYCHAINS=""

say() {
    printf '\n==> %s\n' "$*"
}

warn() {
    printf '\nВНИМАНИЕ: %s\n' "$*"
}

fail() {
    printf '\nОШИБКА: %s\n' "$*"
    exit 1
}

add_warning() {
    WARNINGS="$WARNINGS  - $1"$'\n'
}

# Временная связка ключей sign.sh не должна остаться в списке связок пользователя.
# sign.sh убирает ее сам; это вторая проверка на случай, если его прервали.
restore_keychains() {
    if [[ -z "$SAVED_KEYCHAINS" ]]; then
        return 0
    fi
    if security list-keychains -d user 2>/dev/null | grep -q 'wf\.keychain-db'; then
        echo "Возвращаю прежний список связок ключей."
        # shellcheck disable=SC2086 # список связок ключей нужно разбить на отдельные аргументы
        security list-keychains -d user -s $SAVED_KEYCHAINS || true
    fi
}

on_exit() {
    local rc=$?
    restore_keychains
    rm -rf "$WORK"
    if [[ $rc -ne 0 ]]; then
        echo
        echo "Сборка не закончена, шаг: $STEP (код $rc)."
        echo "Весь вывод сохранен в $LOG"
        echo "Если по сообщению выше непонятно, что делать, пришлите этот файл."
    fi
}
trap on_exit EXIT
trap 'exit 130' INT TERM

# Выполняет команду, вывод идет на экран и в файл $1. Код возврата как у команды.
run_logged() { # файл, команда...
    local out=$1
    shift
    echo "\$ $*"
    "$@" 2>&1 | tee "$out"
}

# 0, если версия $1 не меньше версии $2 (обе вида X.Y.Z).
version_at_least() {
    local a1 a2 a3 b1 b2 b3
    IFS=. read -r a1 a2 a3 <<< "$1"
    IFS=. read -r b1 b2 b3 <<< "$2"
    if [[ $a1 -ne $b1 ]]; then
        [[ $a1 -gt $b1 ]]
        return
    fi
    if [[ $a2 -ne $b2 ]]; then
        [[ $a2 -gt $b2 ]]
        return
    fi
    [[ $a3 -ge $b3 ]]
}

# Самый новый тег v* без v и суффикса. Пусто, если нет .git, git или тегов. Проверка .git
# нужна, чтобы не взять теги чужого репозитория, внутри которого распакован архив.
version_from_tags() {
    if [[ ! -e .git ]] || ! command -v git > /dev/null 2>&1; then
        return 0
    fi
    { git tag -l 'v[0-9]*' 2>/dev/null || true; } |
        sed -nE 's/^v([0-9]+\.[0-9]+\.[0-9]+).*$/\1/p' |
        sort -t. -k1,1n -k2,2n -k3,3n | tail -n 1
}

# --- инструменты ---

say "Проверяю инструменты"
echo "macOS $MACOS_VERSION"

if ! DEV_DIR=$(xcode-select -p 2>/dev/null) || [[ ! -d "$DEV_DIR" ]]; then
    fail "Не найдены инструменты разработчика. Выполните xcode-select --install, дождитесь конца установки и запустите скрипт снова."
fi
echo "Инструменты разработчика: $DEV_DIR"
IS_CLT=0
if [[ "$DEV_DIR" == *CommandLineTools* ]]; then
    IS_CLT=1
fi

if ! SWIFT_INFO=$(swift --version 2>&1); then
    echo "$SWIFT_INFO"
    if [[ "$SWIFT_INFO" == *icense* ]]; then
        fail "Нужно принять лицензию Xcode: sudo xcodebuild -license accept, потом запустить скрипт снова."
    fi
    fail "swift не запускается. Выполните xcode-select --install и запустите скрипт снова."
fi
echo "$SWIFT_INFO"
# Версия Swift вида 6.3. Проверено на 6.3 (CI, Xcode 26); на других версиях сборка может не пройти.
SWIFT_MM=""
SWIFT_PATTERN='Swift version ([0-9]+)\.([0-9]+)'
if [[ "$SWIFT_INFO" =~ $SWIFT_PATTERN ]]; then
    SWIFT_MM="${BASH_REMATCH[1]}.${BASH_REMATCH[2]}"
fi
if [[ "$SWIFT_MM" != 6.3 ]]; then
    warn "Сборка проверена на Swift 6.3, здесь ${SWIFT_MM:-неизвестная версия}."
    add_warning "проверено на Swift 6.3, здесь ${SWIFT_MM:-неизвестная версия}"
fi

# Подсказка, как обновить инструменты разработчика.
update_tools_hint() {
    if [[ $IS_CLT -eq 1 ]]; then
        echo "Обновите Command Line Tools: Системные настройки, «Основные», «Обновление ПО». Или в Терминале: softwareupdate --list, затем sudo softwareupdate --install \"<название Command Line Tools из строки Label>\"."
    else
        echo "Обновите Xcode в App Store."
    fi
}

SDK_VERSION=$(xcrun --sdk macosx --show-sdk-version 2>/dev/null || true)
if [[ "${SDK_VERSION%%.*}" =~ ^[0-9]+$ ]]; then
    echo "SDK macOS $SDK_VERSION"
    if [[ ${SDK_VERSION%%.*} -lt 26 ]]; then
        if [[ $IS_CLT -eq 1 ]]; then
            fail "Command Line Tools устарели (SDK $SDK_VERSION, нужен 26 или новее). $(update_tools_hint) Если обновления нет и там, выполните sudo rm -rf /Library/Developer/CommandLineTools, затем xcode-select --install."
        fi
        fail "Xcode устарел (SDK $SDK_VERSION, нужен 26 или новее). Обновите Xcode в App Store."
    fi
else
    warn "Не удалось узнать версию SDK, продолжаю."
fi

for tool in codesign security ditto plutil xattr uuidgen; do
    if ! command -v "$tool" > /dev/null 2>&1; then
        fail "Нет системной команды $tool, без нее приложение не подписать. Пришлите файл $LOG."
    fi
done
if ! command -v iconutil > /dev/null 2>&1; then
    warn "Нет iconutil, приложение может остаться без иконки. Работе это не мешает."
fi
if [[ ! -x /usr/bin/perl ]]; then
    warn "В системе нет /usr/bin/perl, без него Now Playing (название, обложка, кнопки) не заработает."
    add_warning "нет /usr/bin/perl, Now Playing не заработает"
fi

# --- ключ подписи ---

STEP="ключ подписи"
EXPECTED_LEAF=$(normalize_hash "${SIGNING_EXPECTED_LEAF:-}")
if [[ -z "$EXPECTED_LEAF" && -f signing/expected-leaf.txt ]]; then
    EXPECTED_LEAF=$(normalize_hash "$(cat signing/expected-leaf.txt)")
fi
if [[ -z "$EXPECTED_LEAF" ]]; then
    fail "Нет файла signing/expected-leaf.txt, без него подпись не проверить. Скачайте код заново целиком."
fi

# Сверяет хэш сертификата в папке $1 с ожидаемым. Чужой сертификат не принимается: с ним
# macOS снова спросит доступ к звуку. Подтвержденный ключ сразу копируется в Application
# Support. Если openssl не смог прочитать файл, ключ используется только в этой сборке
# и копируется в Application Support после успешной подписи (PENDING_KEY_DIR).
PENDING_KEY_DIR=""
import_checked_key() { # папка
    local src=$1 rc=0
    signing_leaf_matches "$src" "$EXPECTED_LEAF" || rc=$?
    case $rc in
        0) echo "Хэш сертификата совпал с ожидаемым." ;;
        1) fail "Сертификат в «$src» не тот, которым подписано установленное приложение. С ним macOS снова спросит доступ к звуку, поэтому ключ не импортирован. Нужна копия с ключом WaveFeels Self-Signed." ;;
        *)
            warn "Хэш сертификата до подписи проверить не удалось (openssl не прочитал файл). Проверка пройдет после подписи, в «Application Support» ключ сохранится только если она успешна."
            PENDING_KEY_DIR=$src
            WAVEFEELS_SIGNING_DIR=$src
            export WAVEFEELS_SIGNING_DIR
            return 0
            ;;
    esac
    if ! import_signing_dir "$src"; then
        fail "Не удалось скопировать ключ в «$(signing_app_support_dir)»."
    fi
    echo "Ключ сохранен в «$(signing_app_support_dir)», дальше он берется оттуда."
    # Явно выбранный ключ не должен проигрывать переменной WAVEFEELS_SIGNING_DIR.
    WAVEFEELS_SIGNING_DIR=$(signing_app_support_dir)
    export WAVEFEELS_SIGNING_DIR
}

if [[ -n "$SIGNING_DIR_ARG" ]]; then
    say "Импортирую ключ подписи из «$SIGNING_DIR_ARG»"
    import_checked_key "$SIGNING_DIR_ARG"
elif [[ -n "${SIGNING_P12_BASE64:-}" ]]; then
    echo "Ключ подписи: из переменных SIGNING_P12_BASE64 и SIGNING_P12_PASSWORD"
elif KEY_DIR=$(find_signing_dir); then
    echo "Ключ подписи: $KEY_DIR"
elif OLD_COPY=$(find_downloads_signing_dir "$EXPECTED_LEAF"); then
    say "Нашел старую копию с ключом подписи: «$OLD_COPY»"
    import_checked_key "$OLD_COPY"
else
    fail "Не нашел ключ подписи. Запустите: bash scripts/build-local.sh --signing-dir <папка со старой копией>/signing --install"
fi

# --- версия ---

if [[ -z "$VERSION" ]]; then
    VERSION=$(version_from_tags)
    if [[ -z "$VERSION" ]] || ! version_at_least "$VERSION" "$MIN_VERSION"; then
        VERSION=$MIN_VERSION
    fi
fi
BUILD=$(date +%Y%m%d%H)
if ! [[ "$BUILD" =~ ^[0-9]+$ ]]; then
    fail "Не удалось получить номер сборки из даты: $BUILD"
fi
echo "Версия $VERSION, сборка $BUILD"

# --- тесты ---

tests_need_xcode() {
    local hint="Тесты пропущены: с одними Command Line Tools swift test не находит фреймворк тестов, для --test нужен полный Xcode из App Store."
    if [[ -d /Applications/Xcode.app ]]; then
        hint="$hint Xcode уже установлен, переключиться на него: sudo xcode-select -s /Applications/Xcode.app/Contents/Developer"
    fi
    warn "$hint Сборка продолжается без тестов."
    add_warning "тесты не запускались, для них нужен полный Xcode"
}

# Код 0: тесты прошли. Код 1: тесты упали. Код 2: тесты не запустились, причина не в них.
check_test_run() { # файл с выводом swift test
    if grep -Eq 'failed after|recorded an issue' "$1"; then
        return 1
    fi
    if grep -Eq 'Test run with [0-9]+ tests?.* passed' "$1"; then
        return 0
    fi
    return 2
}

run_tests() {
    local out="$WORK/tests.log" rc verdict
    say "Собираю тесты"
    if run_logged "$out" swift build --build-tests; then
        rc=0
    else
        rc=$?
    fi
    if [[ $rc -ne 0 ]]; then
        if [[ $IS_CLT -eq 1 ]] &&
            grep -Eq "no such module '(Testing|XCTest)'|(Testing|XCTest)\.framework|unable to find utility" "$out"; then
            tests_need_xcode
            return 0
        fi
        fail "Тесты не собрались, ошибки выше. Без тестов приложение собирается командой без --test."
    fi

    say "Запускаю тесты"
    if run_logged "$out" swift test --skip-build; then
        echo "Тесты прошли."
        return 0
    fi
    verdict=0
    check_test_run "$out" || verdict=$?
    if [[ $verdict -eq 1 ]]; then
        fail "Тесты упали, сборка остановлена. Пришлите файл $LOG."
    fi
    if [[ $IS_CLT -eq 0 ]]; then
        fail "swift test завершился с ошибкой, сборка остановлена. Пришлите файл $LOG."
    fi
    if [[ $verdict -eq 0 ]]; then
        # Все тесты Swift Testing прошли, ошибку дал запуск XCTest, которого нет в Command Line Tools.
        echo "Тесты прошли. Ошибку выше дал запуск XCTest, в проекте XCTest не используется."
        return 0
    fi
    say "Пробую запустить тесты без XCTest"
    if run_logged "$out" swift test --skip-build --disable-xctest; then
        echo "Тесты прошли."
        return 0
    fi
    verdict=0
    check_test_run "$out" || verdict=$?
    case $verdict in
        0) echo "Тесты прошли." ;;
        1) fail "Тесты упали, сборка остановлена. Пришлите файл $LOG." ;;
        *) tests_need_xcode ;;
    esac
}

if [[ $RUN_TESTS -eq 1 ]]; then
    STEP="тесты"
    run_tests
fi

# --- приложение ---

STEP="сборка приложения"
say "Собираю приложение (swift build -c release), первый раз это займет несколько минут"
if ! run_logged "$WORK/build.log" swift build -c release; then
    if [[ $IS_CLT -eq 1 ]] && grep -q 'external macro implementation' "$WORK/build.log"; then
        fail "Command Line Tools не хватает для макросов Swift. Поставьте Xcode из App Store, выполните sudo xcode-select -s /Applications/Xcode.app/Contents/Developer и запустите скрипт снова."
    fi
    case "$SWIFT_MM" in
        5.* | 6.0 | 6.1 | 6.2)
            fail "Приложение не собралось, а Swift $SWIFT_MM старее проверенного 6.3. $(update_tools_hint) Потом выполните rm -rf .build и запустите скрипт снова."
            ;;
    esac
    fail "Приложение не собралось, ошибки выше. Пришлите файл $LOG."
fi

# --- адаптер Now Playing ---

STEP="адаптер Now Playing"
# cmake из Homebrew или CMake.app может быть не в PATH. Каталоги добавляются в конец,
# системные утилиты остаются первыми.
for dir in /opt/homebrew/bin /usr/local/bin /Applications/CMake.app/Contents/bin; do
    if [[ -x "$dir/cmake" && ":$PATH:" != *":$dir:"* ]]; then
        PATH="$PATH:$dir"
    fi
done
export PATH

ADAPTER_DIR=""
if command -v cmake > /dev/null 2>&1; then
    say "Собираю адаптер Now Playing из исходников"
    if bash scripts/build-adapter.sh; then
        ADAPTER_DIR=dist/adapter
        echo "Адаптер собран."
    else
        warn "Адаптер не собрался (для него нужен интернет, исходники скачиваются с GitHub). Пробую взять адаптер из установленного WaveFeels."
    fi
fi

if [[ -z "$ADAPTER_DIR" ]]; then
    contents="$INSTALLED/Contents"
    if [[ -f "$contents/Resources/Adapter/mediaremote-adapter.pl" &&
        -d "$contents/Frameworks/MediaRemoteAdapter.framework" &&
        -f "$contents/Helpers/MediaRemoteAdapterTestClient" ]]; then
        say "Беру адаптер Now Playing из $INSTALLED"
        rm -rf dist/adapter-local
        mkdir -p dist/adapter-local
        cp "$contents/Resources/Adapter/mediaremote-adapter.pl" dist/adapter-local/
        # ditto сохраняет символические ссылки внутри фреймворка.
        ditto "$contents/Frameworks/MediaRemoteAdapter.framework" dist/adapter-local/MediaRemoteAdapter.framework
        cp "$contents/Helpers/MediaRemoteAdapterTestClient" dist/adapter-local/
        if [[ -f "$contents/Resources/LICENSES/mediaremote-adapter.txt" ]]; then
            cp "$contents/Resources/LICENSES/mediaremote-adapter.txt" dist/adapter-local/LICENSE
        fi
        xattr -cr dist/adapter-local 2>/dev/null || true
        ADAPTER_DIR=dist/adapter-local
        echo "Адаптер скопирован."
    fi
fi

if [[ -z "$ADAPTER_DIR" ]]; then
    # Каталога нет, bundle.sh соберет приложение без адаптера.
    ADAPTER_DIR=dist/adapter-none
    rm -rf "$ADAPTER_DIR"
    echo
    echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
    echo "ВНИМАНИЕ: сборка без Now Playing. Волны работают, но не будет названия трека,"
    echo "обложки, кнопок в панели и баннера нового трека."
    echo "Чтобы это исправить, поставьте cmake (brew install cmake) или установите"
    echo "WaveFeels 0.9.0 или новее из релизов в «Программы» и запустите скрипт снова."
    echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
    add_warning "сборка без Now Playing: нет названия, обложки, кнопок и баннера"
fi
export ADAPTER_DIR

# --- бандл и подпись ---

STEP="сборка бандла"
say "Собираю dist/WaveFeels.app"
if ! bash scripts/bundle.sh "$VERSION" "$BUILD"; then
    fail "Не удалось собрать dist/WaveFeels.app, ошибки выше. Пришлите файл $LOG."
fi
if [[ ! -f "$APP/Contents/Resources/AppIcon.icns" ]]; then
    warn "Иконка не нарисовалась, у приложения будет стандартный значок. Работе это не мешает."
    add_warning "стандартный значок вместо иконки"
elif [[ ! -f "$APP/Contents/Resources/Assets.car" ]]; then
    echo
    echo "Иконка в формате macOS 26 собирается только полным Xcode, в приложении иконка .icns."
    echo "Работе это не мешает."
fi
# Файлы из архива GitHub, скачанного браузером, несут атрибут карантина. В подписанном
# приложении расширенных атрибутов быть не должно. Атрибуты, которые система снять не дает
# (com.apple.provenance), подписи не мешают.
xattr -cr "$APP" 2>/dev/null || true

STEP="подпись"
say "Подписываю сертификатом WaveFeels Self-Signed"
SAVED_KEYCHAINS=$(security list-keychains -d user | tr -d '"' | grep -v 'wf\.keychain-db' || true)
if ! bash scripts/sign.sh "$APP"; then
    fail "Подпись не удалась. С другой подписью macOS снова спросит доступ к звуку, поэтому сборка остановлена. Пришлите файл $LOG."
fi
restore_keychains

# Ключ, который не удалось проверить заранее, подпись только что подтвердила.
if [[ -n "$PENDING_KEY_DIR" ]]; then
    if import_signing_dir "$PENDING_KEY_DIR"; then
        echo "Подпись подтвердила ключ, он сохранен в «$(signing_app_support_dir)»."
    else
        warn "Не удалось сохранить ключ в «$(signing_app_support_dir)». Укажите его снова через --signing-dir при следующей сборке."
    fi
fi

# --- установка ---

if [[ $INSTALL -eq 1 ]]; then
    STEP="установка"
    if pgrep -x WaveFeels > /dev/null 2>&1; then
        say "Закрываю запущенный WaveFeels"
        echo "Если macOS спросит, можно ли Терминалу управлять WaveFeels, можно отказать:"
        echo "через 10 секунд скрипт закроет приложение сам."
        # osascript в фоне: вопрос macOS про управление приложением не должен останавливать скрипт.
        osascript -e 'quit app "WaveFeels"' > /dev/null 2>&1 &
        osa=$!
        for _ in 1 2 3 4 5 6 7 8 9 10; do
            if ! pgrep -x WaveFeels > /dev/null 2>&1; then
                break
            fi
            sleep 1
        done
        kill "$osa" 2> /dev/null || true
        wait "$osa" 2> /dev/null || true
        # Осиротевшие процессы адаптера WaveFeels убирает сам при следующем запуске.
        if pgrep -x WaveFeels > /dev/null 2>&1; then
            pkill -x WaveFeels || true
            sleep 2
        fi
        if pgrep -x WaveFeels > /dev/null 2>&1; then
            pkill -9 -x WaveFeels || true
            sleep 1
        fi
    fi
    say "Устанавливаю в $INSTALLED"
    if [[ -e "$INSTALLED" ]] && ! rm -rf "$INSTALLED"; then
        fail "Не удалось удалить старый WaveFeels. Перетащите его из «Программ» в Корзину или разрешите Терминалу «Управление приложениями» (Системные настройки, «Конфиденциальность и безопасность») и запустите скрипт снова."
    fi
    if ! ditto "$APP" "$INSTALLED"; then
        fail "Не удалось скопировать приложение в «Программы». Перетащите $APP туда вручную."
    fi
    if open "$INSTALLED"; then
        OPENED=1
    else
        warn "Не удалось открыть WaveFeels, откройте его из «Программ»."
    fi
fi

STEP="готово"
echo
echo "=================================================================="
echo "Готово: WaveFeels $VERSION (сборка $BUILD)."
if [[ $INSTALL -eq 1 ]]; then
    if [[ $OPENED -eq 1 ]]; then
        echo "Установлен в $INSTALLED и запущен."
    else
        echo "Установлен в $INSTALLED. Откройте его из «Программ»."
    fi
else
    echo "Приложение: $APP"
    echo "Чтобы установить, выйдите из WaveFeels и выполните:"
    echo "  rm -rf $INSTALLED && ditto \"$APP\" $INSTALLED && open $INSTALLED"
    echo "Или запустите скрипт с --install."
fi
if [[ -n "$WARNINGS" ]]; then
    echo
    echo "Предупреждения:"
    printf '%s' "$WARNINGS"
fi
echo "Полный вывод: $LOG"
echo "=================================================================="
