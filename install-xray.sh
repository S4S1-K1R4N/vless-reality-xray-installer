#!/usr/bin/env bash
set -euo pipefail

# Xray VLESS + REALITY installer for Ubuntu
# Generated runtime data is stored locally and excluded from version control.

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_USER="${SUDO_USER:-${USER}}"

if [[ "${EUID}" -ne 0 ]]; then
    echo "Run this installer with sudo:"
    echo "  sudo ./install-xray.sh"
    exit 1
fi

if [[ "${INSTALL_USER}" == "root" ]]; then
    echo "Run this from a normal user account with sudo privileges."
    exit 1
fi

INSTALL_GROUP="$(id -gn "${INSTALL_USER}")"

RUNTIME_DIR="${SCRIPT_DIR}/runtime"
BACKUP_DIR="${RUNTIME_DIR}/backups"

XRAY_CONFIG_DIR="/usr/local/etc/xray"
XRAY_CONFIG="${XRAY_CONFIG_DIR}/config.json"

CLIENT_INFO="${RUNTIME_DIR}/client-info.txt"
SERVER_INFO="${RUNTIME_DIR}/server-info.txt"
PRIVATE_KEY_FILE="${RUNTIME_DIR}/reality-private-key.txt"
PUBLIC_KEY_FILE="${RUNTIME_DIR}/reality-public-key.txt"
UUID_FILE="${RUNTIME_DIR}/uuid.txt"
SHORT_ID_FILE="${RUNTIME_DIR}/short-id.txt"
TARGET_FILE="${RUNTIME_DIR}/target.txt"

die() {
    echo
    echo "ERROR: $*"
    exit 1
}

echo
echo "============================================================"
echo " Xray VLESS + REALITY Installer"
echo "============================================================"
echo

# ------------------------------------------------------------
# Runtime directory
# ------------------------------------------------------------

echo "[1/9] Preparing runtime directory..."

mkdir -p "${RUNTIME_DIR}" "${BACKUP_DIR}"

chown -R "${INSTALL_USER}:${INSTALL_GROUP}" "${RUNTIME_DIR}"
chmod 700 "${RUNTIME_DIR}" "${BACKUP_DIR}"

# ------------------------------------------------------------
# Version-control protection
# ------------------------------------------------------------

echo
echo "[2/9] Protecting generated runtime data..."

GITIGNORE="${SCRIPT_DIR}/.gitignore"
touch "${GITIGNORE}"

if ! grep -qxF "runtime/" "${GITIGNORE}"; then
    printf '%s\n' "runtime/" >> "${GITIGNORE}"
fi

chown "${INSTALL_USER}:${INSTALL_GROUP}" "${GITIGNORE}"

# ------------------------------------------------------------
# Dependencies
# ------------------------------------------------------------

echo
echo "[3/9] Installing required packages..."

apt-get update

apt-get install -y \
    curl \
    ca-certificates \
    openssl \
    uuid-runtime \
    jq

# ------------------------------------------------------------
# Xray
# ------------------------------------------------------------

echo
echo "[4/9] Installing/updating Xray..."

bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install

command -v xray >/dev/null 2>&1 || die "Xray installation failed."

xray version

# ------------------------------------------------------------
# REALITY target
# ------------------------------------------------------------

echo
echo "[5/9] Selecting REALITY target"
echo
echo "Enter a normal HTTPS hostname."
echo "It will be tested before configuration."
echo
echo "Press ENTER to use: www.cloudflare.com"
echo

read -r -p "Target hostname [www.cloudflare.com]: " TARGET

TARGET="${TARGET:-www.cloudflare.com}"
TARGET="${TARGET#https://}"
TARGET="${TARGET#http://}"
TARGET="${TARGET%%/*}"
TARGET="${TARGET%%:*}"

[[ -n "${TARGET}" ]] || die "Target hostname is empty."

echo
echo "Testing ${TARGET}:443..."

if ! xray tls ping "${TARGET}:443"; then
    die "TLS target test failed for ${TARGET}:443."
fi

printf '%s\n' "${TARGET}" > "${TARGET_FILE}"

# ------------------------------------------------------------
# Credentials
# ------------------------------------------------------------

echo
echo "[6/9] Generating credentials..."

UUID="$(xray uuid | tr -d '\r\n[:space:]')"
[[ -n "${UUID}" ]] || die "Could not generate UUID."

printf '%s\n' "${UUID}" > "${UUID_FILE}"

KEY_OUTPUT="$(xray x25519)"

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

# Compatibility fallbacks.
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

SHORT_ID="$(openssl rand -hex 8)"
[[ "${SHORT_ID}" =~ ^[0-9a-f]{16}$ ]] || die "Invalid short ID."

printf '%s\n' "${SHORT_ID}" > "${SHORT_ID_FILE}"

chown "${INSTALL_USER}:${INSTALL_GROUP}" \
    "${UUID_FILE}" \
    "${PRIVATE_KEY_FILE}" \
    "${PUBLIC_KEY_FILE}" \
    "${SHORT_ID_FILE}" \
    "${TARGET_FILE}"

chmod 600 \
    "${UUID_FILE}" \
    "${PRIVATE_KEY_FILE}" \
    "${PUBLIC_KEY_FILE}" \
    "${SHORT_ID_FILE}" \
    "${TARGET_FILE}"

# ------------------------------------------------------------
# Xray configuration
# ------------------------------------------------------------

echo
echo "[7/9] Creating Xray configuration..."

mkdir -p "${XRAY_CONFIG_DIR}"

if [[ -f "${XRAY_CONFIG}" ]]; then
    BACKUP_FILE="${BACKUP_DIR}/config-$(date +%Y%m%d-%H%M%S).json"

    cp "${XRAY_CONFIG}" "${BACKUP_FILE}"
    chown "${INSTALL_USER}:${INSTALL_GROUP}" "${BACKUP_FILE}"
    chmod 600 "${BACKUP_FILE}"
fi

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

# The standard Xray systemd service runs as nobody.
# It needs read access to the configuration.
chown root:nogroup "${XRAY_CONFIG}"
chmod 640 "${XRAY_CONFIG}"

echo
echo "Validating configuration..."

xray run -test -config "${XRAY_CONFIG}" ||
    die "Xray configuration validation failed."

# ------------------------------------------------------------
# Firewall
# ------------------------------------------------------------

echo
echo "[8/9] Configuring local firewall..."

if command -v ufw >/dev/null 2>&1; then
    ufw allow OpenSSH >/dev/null || true
    ufw allow 443/tcp >/dev/null || true

    if ufw status | grep -q "Status: inactive"; then
        ufw --force enable >/dev/null
    fi

    ufw status
fi

# ------------------------------------------------------------
# Service
# ------------------------------------------------------------

echo
echo "[9/9] Starting Xray..."

systemctl daemon-reload
systemctl enable xray
systemctl restart xray

sleep 2

if ! systemctl is-active --quiet xray; then
    systemctl --no-pager -l status xray || true
    journalctl -u xray --no-pager -n 50 || true
    die "Xray failed to start."
fi

echo
echo "Checking TCP 443..."

if ! ss -lntp | grep -q ':443'; then
    echo "WARNING: TCP 443 is not currently shown as listening."
fi

# ------------------------------------------------------------
# Client information
# ------------------------------------------------------------

cat > "${CLIENT_INFO}" <<EOF
============================================================
Xray VLESS + REALITY
============================================================

SERVER:
YOUR_SERVER_PUBLIC_IP

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

vless://${UUID}@YOUR_SERVER_PUBLIC_IP:443?encryption=none&security=reality&sni=${TARGET}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&flow=xtls-rprx-vision&type=tcp#Xray-REALITY

============================================================
Replace YOUR_SERVER_PUBLIC_IP with the server's public IP.
The REALITY private key stays on the server.
============================================================
EOF

cat > "${SERVER_INFO}" <<EOF
Xray VLESS + REALITY

Xray:
$(xray version | head -n 1)

Listen:
0.0.0.0:443

Target:
${TARGET}:443

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

chown "${INSTALL_USER}:${INSTALL_GROUP}" \
    "${CLIENT_INFO}" \
    "${SERVER_INFO}"

chmod 600 "${CLIENT_INFO}" "${SERVER_INFO}"

# Ensure runtime remains accessible to the installing user.
chown -R "${INSTALL_USER}:${INSTALL_GROUP}" "${RUNTIME_DIR}"
chmod 700 "${RUNTIME_DIR}" "${BACKUP_DIR}"

chmod 600 \
    "${PRIVATE_KEY_FILE}" \
    "${PUBLIC_KEY_FILE}" \
    "${UUID_FILE}" \
    "${SHORT_ID_FILE}" \
    "${TARGET_FILE}" \
    "${CLIENT_INFO}" \
    "${SERVER_INFO}"

echo
echo "============================================================"
echo " INSTALLATION COMPLETE"
echo "============================================================"
echo
echo "Service:"
echo "  $(systemctl is-active xray)"
echo
echo "Client configuration:"
echo "  ${CLIENT_INFO}"
echo
echo "Runtime directory:"
echo "  ${RUNTIME_DIR}"
echo
echo "Listening:"
ss -lntp | grep ':443' || true
echo
echo "The host firewall allows SSH and TCP 443."
echo "Configure any external firewall/security group separately."
echo
