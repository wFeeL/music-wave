#!/usr/bin/env bash
# Подписывает приложение самоподписанным сертификатом WaveFeels Self-Signed.
# Использование: scripts/sign.sh <path/to/WaveFeels.app>
#
# Сертификат: секреты SIGNING_P12_BASE64 + SIGNING_P12_PASSWORD, если заданы, иначе
# signing/wavefeels-signing.p12 + signing/password.txt. Нет ни того, ни другого:
# ad-hoc с предупреждением. Сертификат есть, но подпись не удалась: код 1 (тихий
# откат на ad-hoc запрещен, он сбрасывает разрешение на звук).
# Шаг доверия (add-trusted-cert) не используется: codesign подписывает по SHA-1,
# designated requirement задается явно.
# Хэш листового сертификата в designated requirement сверяется с ожидаемым: значение из
# переменной SIGNING_EXPECTED_LEAF, если она задана, иначе из signing/expected-leaf.txt.
# Не совпал (в секреты попал другой сертификат) или ожидаемого нет: код 1, иначе macOS
# сочтет сборку другим приложением и снова спросит доступ к звуку.
# Вывод идет в stdout/stderr; ci-mac.sh сохраняет его в ci-out/sign.txt.
set -euo pipefail

cd "$(dirname "$0")/.."

if [[ $# -ne 1 || ! -d "$1" ]]; then
    echo "usage: $0 <path/to/WaveFeels.app>" >&2
    exit 2
fi
APP=$1
IDENTIFIER=com.wfeels.wavefeels
CERT_NAME="WaveFeels Self-Signed"
FRAMEWORK="$APP/Contents/Frameworks/MediaRemoteAdapter.framework"
HELPER="$APP/Contents/Helpers/MediaRemoteAdapterTestClient"

WORK=$(mktemp -d)
TMP_ROOT=${RUNNER_TEMP:-$WORK}
KC="$TMP_ROOT/wf.keychain-db"
ORIGINAL_KEYCHAINS=""

cleanup() {
    local rc=$?
    if [[ -n "$ORIGINAL_KEYCHAINS" ]]; then
        # shellcheck disable=SC2086 # список связок ключей нужно разбить на отдельные аргументы
        security list-keychains -d user -s $ORIGINAL_KEYCHAINS || true
    fi
    if [[ -f "$KC" ]]; then
        security delete-keychain "$KC" || true
    fi
    rm -rf "$WORK"
    # Любой сбой после выбора сертификата дает код 1.
    if [[ $rc -ne 0 ]]; then
        exit 1
    fi
}
trap cleanup EXIT

P12=""
PW=""
if [[ -n "${SIGNING_P12_BASE64:-}" && -z "${SIGNING_P12_PASSWORD:-}" ]] ||
    [[ -z "${SIGNING_P12_BASE64:-}" && -n "${SIGNING_P12_PASSWORD:-}" ]]; then
    echo "error: set both SIGNING_P12_BASE64 and SIGNING_P12_PASSWORD, or neither" >&2
    exit 1
fi
if [[ -n "${SIGNING_P12_BASE64:-}" ]]; then
    echo "certificate source: repository secrets"
    P12="$WORK/signing.p12"
    printf '%s' "$SIGNING_P12_BASE64" | base64 --decode > "$P12"
    PW=$SIGNING_P12_PASSWORD
elif [[ -f signing/wavefeels-signing.p12 && -f signing/password.txt ]]; then
    echo "certificate source: signing/ files"
    P12=signing/wavefeels-signing.p12
    PW=$(tr -d '\r\n' < signing/password.txt)
fi

sign_nested() {
    # Вложенный код подписывается раньше приложения. Аргументы: параметры личности для codesign.
    if [[ -d "$FRAMEWORK" ]]; then
        codesign --force --timestamp=none "$@" "$FRAMEWORK"
    fi
    if [[ -f "$HELPER" ]]; then
        codesign --force --timestamp=none "$@" "$HELPER"
    fi
}

report() {
    # Подписи вложенного кода адаптера, если он есть в бандле, затем приложения.
    local nested
    for nested in "$FRAMEWORK" "$HELPER"; do
        if [[ -e "$nested" ]]; then
            codesign --verify --strict --verbose=2 "$nested" 2>&1
            codesign -dvv "$nested" 2>&1
        fi
    done
    codesign --verify --deep --strict --verbose=2 "$APP" 2>&1
    codesign -dvv "$APP" 2>&1
    codesign -dr - "$APP" 2>&1
}

if [[ -z "$P12" ]]; then
    echo "WARNING: no signing certificate (no secrets, no signing/ files), signing ad-hoc;"
    echo "WARNING: audio capture permission will reset after every install"
    sign_nested --sign -
    codesign --force --timestamp=none --sign - --identifier "$IDENTIFIER" "$APP"
    report
    exit 0
fi

KP=$(uuidgen)
if [[ -f "$KC" ]]; then
    security delete-keychain "$KC" || true
fi
ORIGINAL_KEYCHAINS=$(security list-keychains -d user | tr -d '"')

security create-keychain -p "$KP" "$KC"
security set-keychain-settings -lut 21600 "$KC"
security unlock-keychain -p "$KP" "$KC"
security import "$P12" -k "$KC" -P "$PW" -T /usr/bin/codesign -f pkcs12
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KP" "$KC" >/dev/null
# shellcheck disable=SC2086 # список связок ключей нужно разбить на отдельные аргументы
security list-keychains -d user -s "$KC" $ORIGINAL_KEYCHAINS

# Без -v: недоверенная личность в списке с -v не появляется.
security find-identity -p codesigning "$KC"
SHA=$(security find-identity -p codesigning "$KC" | awk -v name="\"$CERT_NAME\"" 'index($0, name) {print $2; exit}')
if [[ -z "$SHA" ]]; then
    echo "error: identity '$CERT_NAME' not found in imported keychain" >&2
    exit 1
fi
echo "signing identity: $CERT_NAME ($SHA)"

EXPECTED_LEAF=${SIGNING_EXPECTED_LEAF:-}
if [[ -z "$EXPECTED_LEAF" && -f signing/expected-leaf.txt ]]; then
    EXPECTED_LEAF=$(tr -d ' \r\n' < signing/expected-leaf.txt)
fi
if [[ -z "$EXPECTED_LEAF" ]]; then
    echo "error: no expected leaf hash (SIGNING_EXPECTED_LEAF or signing/expected-leaf.txt)" >&2
    exit 1
fi
EXPECTED_LEAF=$(printf '%s' "$EXPECTED_LEAF" | tr '[:upper:]' '[:lower:]')

REQ="=designated => identifier \"$IDENTIFIER\" and certificate leaf = H\"$SHA\""
sign_nested --keychain "$KC" --sign "$SHA"
codesign --force --timestamp=none --keychain "$KC" --sign "$SHA" --identifier "$IDENTIFIER" -r "$REQ" "$APP"
report

# Хэш листа в подписанном designated requirement: H"<40 hex>".
DR=$(codesign -dr - "$APP" 2>&1)
LEAF=""
LEAF_PATTERN='certificate leaf = H"([0-9A-Fa-f]+)"'
if [[ $DR =~ $LEAF_PATTERN ]]; then
    LEAF=$(printf '%s' "${BASH_REMATCH[1]}" | tr '[:upper:]' '[:lower:]')
fi
echo "leaf hash: ${LEAF:-none}, expected: $EXPECTED_LEAF"
if [[ "$LEAF" != "$EXPECTED_LEAF" ]]; then
    echo "error: designated requirement leaf hash ${LEAF:-none} differs from expected $EXPECTED_LEAF" >&2
    echo "error: a different certificate would reset the audio capture permission;" >&2
    echo "error: if the change is intended, update signing/expected-leaf.txt or SIGNING_EXPECTED_LEAF" >&2
    exit 1
fi
