#!/usr/bin/env bash
# Создает свой ключ подписи WaveFeels для первой сборки на этом маке.
# Использование: bash scripts/make-signing-key.sh
# Результат в ~/Library/Application Support/WaveFeels/signing: wavefeels-signing.p12,
# password.txt и expected-leaf.txt (хэш сертификата, по нему build-local.sh и sign.sh
# проверяют подпись). Сертификат самоподписанный, CN «WaveFeels Self-Signed», как у make-cert.sh.
# Если ключ уже есть (Application Support, $WAVEFEELS_SIGNING_DIR, signing/ в репозитории,
# старая копия в ~/Downloads/music-wave-develop*), скрипт ничего не создает: новый ключ
# сбросил бы разрешение на звук. Рассчитан на bash 3.2 и LibreSSL из macOS.
set -euo pipefail

cd "$(dirname "$0")/.."
# shellcheck source=scripts/signing-source.sh
source scripts/signing-source.sh

CN="WaveFeels Self-Signed"

case "${1:-}" in
    -h | --help)
        sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//'
        exit 0
        ;;
    "") ;;
    *)
        echo "Неизвестный ключ: $1. Справка: bash scripts/make-signing-key.sh --help" >&2
        exit 2
        ;;
esac

DEST=$(signing_app_support_dir)

if EXISTING=$(find_signing_dir 2> /dev/null); then
    echo "Ключ подписи уже есть: «$EXISTING». Новый не нужен, запускайте сборку:"
    echo "  bash scripts/build-local.sh --install"
    exit 0
fi
if [[ -e "$DEST/$SIGNING_P12_NAME" || -e "$DEST/$SIGNING_PASSWORD_NAME" ]]; then
    echo "В «$DEST» лежит только часть ключа. Проверьте папку: если ключ потерян, уберите ее и запустите скрипт снова." >&2
    exit 1
fi
for old in "$HOME"/Downloads/music-wave-develop*/signing; do
    if signing_dir_has_pair "$old"; then
        echo "В «$old» лежит старый ключ подписи. Новый создавать не нужно, укажите эту папку при сборке:" >&2
        echo "  bash scripts/build-local.sh --signing-dir \"$old\" --install" >&2
        exit 1
    fi
done

# На маке берется системный LibreSSL: openssl из Homebrew по умолчанию шифрует p12 так,
# что security может его не импортировать.
OPENSSL=openssl
if [[ -x /usr/bin/openssl ]]; then
    OPENSSL=/usr/bin/openssl
fi
if ! command -v "$OPENSSL" > /dev/null 2>&1; then
    echo "Нет команды openssl, ключ не создать." >&2
    exit 1
fi

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
umask 077

cat > "$WORK/cert.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = codesign
prompt = no

[dn]
CN = $CN

[codesign]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
subjectKeyIdentifier = hash
EOF

echo "Создаю ключ подписи…"
"$OPENSSL" req -x509 -newkey rsa:2048 -nodes -sha256 -days 3650 -config "$WORK/cert.cnf" \
    -keyout "$WORK/key.pem" -out "$WORK/cert.pem" 2> "$WORK/openssl.log" ||
    { cat "$WORK/openssl.log" >&2; echo "Не удалось создать сертификат." >&2; exit 1; }
"$OPENSSL" rand -hex 24 > "$WORK/$SIGNING_PASSWORD_NAME"
"$OPENSSL" pkcs12 -export -inkey "$WORK/key.pem" -in "$WORK/cert.pem" -name "$CN" \
    -passout "file:$WORK/$SIGNING_PASSWORD_NAME" -out "$WORK/$SIGNING_P12_NAME" 2> "$WORK/openssl.log" ||
    { cat "$WORK/openssl.log" >&2; echo "Не удалось упаковать ключ в p12." >&2; exit 1; }
LEAF=$("$OPENSSL" x509 -in "$WORK/cert.pem" -noout -fingerprint -sha1)
LEAF=$(normalize_hash "${LEAF#*=}")

# p12 должен читаться тем же путем, что и при сборке, и давать тот же хэш.
if ! CHECK=$(signing_leaf_hash "$WORK") || [[ "$CHECK" != "$LEAF" ]]; then
    echo "Созданный ключ не прошел проверку, в «$DEST» ничего не записано." >&2
    exit 1
fi

mkdir -p "$DEST"
chmod 700 "$DEST"
printf '%s\n' "$LEAF" > "$WORK/expected-leaf.txt"
for name in "$SIGNING_PASSWORD_NAME" expected-leaf.txt "$SIGNING_P12_NAME"; do
    cp "$WORK/$name" "$DEST/$name"
    chmod 600 "$DEST/$name"
done

echo "Ключ создан: «$DEST»."
echo "Сохраните копию этой папки: с новым ключом macOS снова спросит доступ к звуку."
echo "Дальше: bash scripts/build-local.sh --install"
