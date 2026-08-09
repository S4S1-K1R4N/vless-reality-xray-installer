#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# Xray VLESS + REALITY installer
#
# Repository:
#   ~/vless-reality-xray-installer
#
# Generated runtime/secrets:
#   ~/vless-reality-xray-installer/runtime
#
# Xray configuration:
#   /usr/local/etc/xray/config.json
#
# The runtime directory MUST NOT be committed to Git.
# ============================================================

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
RUNTIME_DIR="${SCRIPT_DIR}/runtime"

XRAY_CONFIG="/usr/local/etc/xray/config.json"
XRAY_CONFIG_DIR="/usr/local/etc/xray"

CLIENT_INFO="${RUNTIME_DIR}/client-info.txt"
SERVER_INFO="${RUNTIME_DIR}/server-info.txt"
PRIVATE_KEY_FILE="${RUNTIME_DIR}/reality-private-key.txt"
PUBLIC_KEY_FILE="${RUNTIME_DIR}/reality-public-key.txt"
UUID_FILE="${RUNTIME_DIR}/uuid.txt"
SHORT_ID_FILE="${RUNTIME_DIR}/short-id.txt"
TARGET_FILE="${RUNTIME_DIR}/target.txt"

BACKUP_DIR="${RUNTIME_DIR}/backups"

# ------------------------------------------------------------
# Helpers
# ------------------------------------------------------------

die() {
    echo
    echo "ERROR: $*"
    echo
    exit 1
}

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# ------------------------------------------------------------
# Check root
# ------------------------------------------------------------

if [[ "${EUID}" -ne 0 ]]; then
    die "Run this script with sudo:

    sudo ./install-xray.sh"
fi

echo
echo "============================================================"
echo " Xray VLESS + REALITY Installer"
echo "============================================================"
echo
echo "Repository:"
echo "  ${SCRIPT_DIR}"
echo
echo "Runtime data:"
echo "  ${RUNTIME_DIR}"
echo

# ------------------------------------------------------------
# 1. Create runtime directory
# ------------------------------------------------------------

echo "[1/9] Preparing runtime directory..."

mkdir -p "${RUNTIME_DIR}"
mkdir -p "${BACKUP_DIR}"

# Only root should be able to read generated secrets.
chown -R root:root "${RUNTIME_DIR}"
chmod 700 "${RUNTIME_DIR}"
chmod 700 "${BACKUP_DIR}"

# ------------------------------------------------------------
# 2. Install required packages
# ------------------------------------------------------------

echo
echo "[2/9] Installing required packages..."

apt-get update

apt-get install -y \
    curl \
    ca-certificates \
    openssl \
    uuid-runtime \
    jq

# ------------------------------------------------------------
# 3. Install/update Xray
# ------------------------------------------------------------

echo
echo "[3/9] Installing/updating Xray..."

bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install

command_exists xray || die "Xray installation failed."

echo
echo "Installed Xray:"
xray version

# ------------------------------------------------------------
# 4. Select REALITY target
# ------------------------------------------------------------

echo
echo "[4/9] Selecting REALITY target"
echo
echo "Enter a normal HTTPS hostname."
echo
echo "The target will be tested with:"
echo
echo "    xray tls ping HOST:443"
echo
echo "Press ENTER to use:"
echo
echo "    www.cloudflare.com"
echo

read -r -p "Target hostname [www.cloudflare.com]: " TARGET

TARGET="${TARGET:-www.cloudflare.com}"

# Clean accidental protocol/path/port input.
TARGET="${TARGET#https://}"
TARGET="${TARGET#http://}"
TARGET="${TARGET%%/*}"
TARGET="${TARGET%%:*}"

[[ -n "${TARGET}" ]] || die "Target hostname is empty."

echo
echo "Testing:"
echo "    ${TARGET}:443"
echo

if ! xray tls ping "${TARGET}:443"; then
    die "TLS test failed for ${TARGET}:443.

Choose another HTTPS hostname and run the installer again."
fi

echo
echo "TLS target test succeeded."

printf '%s\n' "${TARGET}" > "${TARGET_FILE}"

# ------------------------------------------------------------
# 5. Generate UUID
# ------------------------------------------------------------

echo
echo "[5/9] Generating VLESS UUID..."

UUID="$(xray uuid | tr -d '\r\n[:space:]')"

[[ -n "${UUID}" ]] || die "Could not generate UUID."

printf '%s\n' "${UUID}" > "${UUID_FILE}"

echo "UUID generated."

# ------------------------------------------------------------
# 6. Generate REALITY key pair
# ------------------------------------------------------------

echo
echo "[6/9] Generating REALITY X25519 key pair..."

KEY_OUTPUT="$(xray x25519)"

echo
echo "Xray key generator:"
echo "${KEY_OUTPUT}"
echo

# Current Xray format:
#
# PrivateKey: ...
# Password (PublicKey): ...
# Hash32: ...
#
PRIVATE_KEY="$(
    printf '%s\n' "${KEY_OUTPUT}" |
    sed -n 's/^PrivateKey: //p' |
    head -n 1 |
    tr -d '\r'
)"

PUBLIC_KEY="$(
    printf '%s\n' "${KEY_OUTPUT}" |
    sed -n 's/^Password (PublicKey): //p' |
    head -n 1 |
    tr -d '\r'
)"

# Compatibility fallback for older versions.
if [[ -z "${PRIVATE_KEY}" ]]; then
    PRIVATE_KEY="$(
        printf '%s\n' "${KEY_OUTPUT}" |
        sed -n 's/^Private key: //p' |
        head -n 1 |
        tr -d '\r'
    )"
fi

if [[ -z "${PUBLIC_KEY}" ]]; then
    PUBLIC_KEY="$(
        printf '%s\n' "${KEY_OUTPUT}" |
        sed -n 's/^Password: //p' |
        head -n 1 |
        tr -d '\r'
    )"
fi

if [[ -z "${PUBLIC_KEY}" ]]; then
    PUBLIC_KEY="$(
        printf '%s\n' "${KEY_OUTPUT}" |
        sed -n 's/^PublicKey: //p' |
        head -n 1 |
        tr -d '\r'
    )"
fi

[[ -n "${PRIVATE_KEY}" ]] || die "Could not extract REALITY private key."

[[ -n "${PUBLIC_KEY}" ]] || die "Could not extract REALITY public key."

printf '%s\n' "${PRIVATE_KEY}" > "${PRIVATE_KEY_FILE}"
printf '%s\n' "${PUBLIC_KEY}" > "${PUBLIC_KEY_FILE}"

chmod 600 "${PRIVATE_KEY_FILE}"
chmod 600 "${PUBLIC_KEY_FILE}"

echo "REALITY key pair generated."

# ------------------------------------------------------------
# Generate short ID
# ------------------------------------------------------------

SHORT_ID="$(openssl rand -hex 8)"

[[ "${SHORT_ID}" =~ ^[0-9a-f]{16}$ ]] ||
    die "Generated invalid REALITY short ID."

printf '%s\n' "${SHORT_ID}" > "${SHORT_ID_FILE}"

chmod 600 "${UUID_FILE}"
chmod 600 "${SHORT_ID_FILE}"
chmod 600 "${TARGET_FILE}"

echo "Short ID generated."

# ------------------------------------------------------------
# 7. Backup existing Xray configuration
# ------------------------------------------------------------

echo
echo "[7/9] Preparing Xray configuration..."

mkdir -p "${XRAY_CONFIG_DIR}"

if [[ -f "${XRAY_CONFIG}" ]]; then

    BACKUP_FILE="${BACKUP_DIR}/config-$(date +%Y%m%d-%H%M%S).json"

    cp "${XRAY_CONFIG}" "${BACKUP_FILE}"

    chmod 600 "${BACKUP_FILE}"

    echo "Existing configuration backed up:"
    echo "  ${BACKUP_FILE}"
fi

# ------------------------------------------------------------
# Write Xray configuration
# ------------------------------------------------------------

cat > "${XRAY_CONFIG}" <<EOF
{
  "log": {
    "loglevel": "warning"
  },

  "inbounds": [
    {
      "listen": "0.0.0.0",
      "port": 443,
      "protocol": "vless",

      "settings": {
        "clients": [
          {
            "id": "${UUID}",
            "flow": "xtls-rprx-vision"
          }
        ],
        "decryption": "none"
      },

      "streamSettings": {
        "network": "raw",
        "security": "reality",

        "realitySettings": {
          "show": false,
          "target": "${TARGET}:443",
          "xver": 0,

          "serverNames": [
            "${TARGET}"
          ],

          "privateKey": "${PRIVATE_KEY}",

          "shortIds": [
            "${SHORT_ID}"
          ]
        }
      }
    }
  ],

  "outbounds": [
    {
      "protocol": "freedom"
    }
  ]
}
EOF

# IMPORTANT:
# The Xray systemd service installed by the official installer
# runs as "nobody". It therefore needs read access to config.json.
#
# root owns the file.
# group "nogroup" gets read access.
# nobody belongs to nogroup on standard Ubuntu installations.

chown root:nogroup "${XRAY_CONFIG}"
chmod 640 "${XRAY_CONFIG}"

# ------------------------------------------------------------
# Validate configuration
# ------------------------------------------------------------

echo
echo "Validating Xray configuration..."

if ! xray run -test -config "${XRAY_CONFIG}"; then
    die "Xray configuration validation failed."
fi

echo
echo "Configuration validation successful."

# ------------------------------------------------------------
# 8. Configure UFW
# ------------------------------------------------------------

echo
echo "[8/9] Configuring Ubuntu firewall..."

if command_exists ufw; then

    ufw allow OpenSSH >/dev/null || true
    ufw allow 443/tcp >/dev/null || true

    if ufw status | grep -q "Status: inactive"; then
        ufw --force enable >/dev/null
    fi

    echo
    echo "UFW status:"
    ufw status
else
    echo "UFW is not installed."
fi

# ------------------------------------------------------------
# 9. Start Xray
# ------------------------------------------------------------

echo
echo "[9/9] Starting Xray..."

systemctl daemon-reload
systemctl enable xray
systemctl restart xray

sleep 2

if ! systemctl is-active --quiet xray; then

    echo
    echo "============================================================"
    echo " Xray FAILED TO START"
    echo "============================================================"
    echo

    systemctl --no-pager -l status xray || true

    echo
    echo "Recent logs:"
    journalctl -u xray --no-pager -n 50 || true

    exit 1
fi

# ------------------------------------------------------------
# Verify listener
# ------------------------------------------------------------

echo
echo "Checking TCP 443..."

if ss -lntp | grep -q ':443'; then
    echo "SUCCESS: Xray is listening on TCP 443."
else
    echo
    echo "WARNING: TCP 443 does not appear to be listening."
fi

# ------------------------------------------------------------
# Create client information
# ------------------------------------------------------------

cat > "${CLIENT_INFO}" <<EOF
============================================================
Xray VLESS + REALITY
============================================================

SERVER:
YOUR_AZURE_PUBLIC_IP

PORT:
443

PROTOCOL:
VLESS

UUID:
${UUID}

ENCRYPTION:
none

FLOW:
xtls-rprx-vision

TRANSPORT:
RAW

SECURITY:
REALITY

SNI / SERVER NAME:
${TARGET}

FINGERPRINT:
chrome

REALITY PUBLIC KEY:
${PUBLIC_KEY}

SHORT ID:
${SHORT_ID}

REALITY TARGET:
${TARGET}:443


VLESS URI:

vless://${UUID}@YOUR_AZURE_PUBLIC_IP:443?encryption=none&security=reality&sni=${TARGET}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&flow=xtls-rprx-vision&type=tcp#Azure-Xray


============================================================
IMPORTANT
============================================================

Replace:

    YOUR_AZURE_PUBLIC_IP

with your Azure VM public IP.

DO NOT share the REALITY private key.

The client uses the REALITY PUBLIC KEY.
============================================================
EOF

chmod 600 "${CLIENT_INFO}"

# ------------------------------------------------------------
# Server information
# ------------------------------------------------------------

cat > "${SERVER_INFO}" <<EOF
Xray VLESS + REALITY server

Installed Xray:
$(xray version | head -n 1)

Target:
${TARGET}:443

Listen:
0.0.0.0:443

Protocol:
VLESS

Transport:
RAW

Security:
REALITY

UUID:
${UUID}

Short ID:
${SHORT_ID}
EOF

chmod 600 "${SERVER_INFO}"

# ------------------------------------------------------------
# Final output
# ------------------------------------------------------------

echo
echo
echo "============================================================"
echo " INSTALLATION COMPLETE"
echo "============================================================"
echo

echo "Xray:"
systemctl is-active xray

echo
echo "Listening:"
ss -lntp | grep ':443' || true

echo
echo "Repository:"
echo "  ${SCRIPT_DIR}"

echo
echo "Generated runtime files:"
echo "  ${RUNTIME_DIR}/"

echo
echo "Client configuration:"
echo "  ${CLIENT_INFO}"

echo
echo "Show client information:"
echo "  sudo cat '${CLIENT_INFO}'"

echo
echo "Server configuration:"
echo "  ${XRAY_CONFIG}"

echo
echo "============================================================"
echo " AZURE REQUIREMENT"
echo "============================================================"
echo
echo "Azure NSG must allow:"
echo
echo "  TCP 443"
echo
echo "SSH remains on:"
echo "  TCP 22"
echo
echo "Do NOT expose port 8080 for this configuration."
echo
echo "============================================================"
