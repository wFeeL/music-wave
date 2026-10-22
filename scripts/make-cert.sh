#!/usr/bin/env bash
# Создает самоподписанный сертификат подписи кода WaveFeels (запускается один раз, на Linux).
# Результат: signing/wavefeels-signing.p12 и signing/password.txt.
# Повторный запуск без --force отказывается перезаписывать: новый сертификат
# меняет designated requirement и сбрасывает разрешение на звук у владельца.
set -euo pipefail

cd "$(dirname "$0")/.."

OUT_DIR="signing"
P12="$OUT_DIR/wavefeels-signing.p12"
PW_FILE="$OUT_DIR/password.txt"
CN="WaveFeels Self-Signed"

if [[ -e "$P12" && "${1:-}" != "--force" ]]; then
    echo "error: $P12 already exists; pass --force to replace it" >&2
    exit 1
fi

mkdir -p "$OUT_DIR"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# Собственный конфиг вместо системного: системный добавляет v3_ca с CA:true.
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

openssl req -x509 -newkey rsa:2048 -noenc -sha256 -days 3650 \
    -config "$WORK/cert.cnf" \
    -keyout "$WORK/key.pem" -out "$WORK/cert.pem"

openssl rand -hex 24 > "$PW_FILE"

openssl pkcs12 -export -legacy \
    -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
    -name "$CN" \
    -passout "file:$PW_FILE" \
    -out "$P12"

openssl pkcs12 -legacy -in "$P12" -noout -passin "file:$PW_FILE"
openssl x509 -in "$WORK/cert.pem" -noout -subject -enddate -fingerprint -sha1
echo "wrote $P12 and $PW_FILE"
