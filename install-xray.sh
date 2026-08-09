#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

# The normal user who invoked sudo.
INSTALL_USER="${SUDO_USER:-${USER}}"

if [[ "${INSTALL_USER}" == "root" ]]; then
    echo "ERROR: Run this as:"
    echo
    echo "    sudo ./install-xray.sh"
    echo
    echo "from your normal Azure user."
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

# ------------------------------------------------------------
# Helper
# ------------------------------------------------------------

die() {
    echo
    echo "============================================================"
    echo "ERROR"
    echo "============================================================"
    echo
    echo "$*"
    echo
    exit 1
}

echo
echo "============================================================"
echo " Xray VLESS + REALITY Installer"
echo "============================================================"
echo
echo "Install user:"
echo "  ${INSTALL_USER}"
echo
echo "Repository:"
echo "  ${SCRIPT_DIR}"
echo
echo "Runtime:"
echo "  ${RUNTIME_DIR}"
echo

# ------------------------------------------------------------
# Root check
# ------------------------------------------------------------

if [[ "${EUID}" -ne 0 ]]; then
    die "Run this script with sudo:

    sudo ./install-xray.sh"
fi

# ------------------------------------------------------------
# Verify normal user exists
# ------------------------------------------------------------

id "${INSTALL_USER}" >/dev/null 2>&1 ||
    die "User '${INSTALL_USER}' does not exist."

# ------------------------------------------------------------
# 1. Prepare runtime
# ------------------------------------------------------------

echo "[1/9] Preparing runtime directory..."

mkdir -p "${RUNTIME_DIR}"
mkdir -p "${BACKUP_DIR}"

# Let the normal Azure user manage runtime completely.
chown -R "${INSTALL_USER}:${INSTALL_GROUP}" "${RUNTIME_DIR}"

# User can enter/read/write runtime.
chmod 700 "${RUNTIME_DIR}"
chmod 700 "${BACKUP_DIR}"

# ------------------------------------------------------------
# 2. Make sure runtime is ignored by Git
# ------------------------------------------------------------

echo
echo "[2/9] Configuring Git protection..."

GITIGNORE="${SCRIPT_DIR}/.gitignore"

touch "${GITIGNORE}"

if ! grep -qxF "runtime/" "${GITIGNORE}"; then
    printf '%s\n' "runtime/" >> "${GITIGNORE}"
fi

chown "${INSTALL_USER}:${INSTALL_GROUP}" "${GITIGNORE}"

echo "runtime/ is protected from Git commits."

# ------------------------------------------------------------
# 3. Install dependencies
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
# 4. Install/update Xray
# ------------------------------------------------------------

echo
echo "[4/9] Installing/updating Xray..."

bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install

command -v xray >/dev/null 2>&1 ||
    die "Xray installation failed."

echo
echo "Installed:"
xray version

# ------------------------------------------------------------
# 5. REALITY target
# ------------------------------------------------------------

echo
echo "[5/9] Selecting REALITY target"
echo
echo "Enter a normal HTTPS hostname."
echo
echo "It will be tested with:"
echo
echo "    xray tls ping HOST:443"
echo
echo "Press ENTER for:"
echo
echo "    www.cloudflare.com"
echo

read -r -p "Target hostname [www.cloudflare.com]: " TARGET

TARGET="${TARGET:-www.cloudflare.com}"

# Clean common accidental input.
TARGET="${TARGET#https://}"
TARGET="${TARGET#http://}"
TARGET="${TARGET%%/*}"
TARGET="${TARGET%%:*}"

[[ -n "${TARGET}" ]] ||
    die "Target hostname is empty."

echo
echo "Testing ${TARGET}:443 ..."
echo

if ! xray tls ping "${TARGET}:443"; then
    die "TLS test failed for ${TARGET}:443.

Choose another valid HTTPS hostname and run the installer again."
fi

echo
echo "TLS target test succeeded."

printf '%s\n' "${TARGET}" > "${TARGET_FILE}"

# ------------------------------------------------------------
# 6. Generate UUID
# ------------------------------------------------------------

echo
echo "[6/9] Generating UUID..."

UUID="$(xray uuid | tr -d '\r\n[:space:]')"

[[ -n "${UUID}" ]] ||
    die "Could not generate UUID."

printf '%s\n' "${UUID}" > "${UUID_FILE}"

echo "UUID generated."

# ------------------------------------------------------------
# Generate REALITY X25519 keys
# ------------------------------------------------------------

echo
echo "Generating REALITY X25519 key pair..."

KEY_OUTPUT="$(xray x25519)"

echo
echo "Xray key generator output:"
echo "${KEY_OUTPUT}"
echo

# Xray 26.x:
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

# Older-version compatibility.
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

[[ -n "${PRIVATE_KEY}" ]] ||
    die "Could not extract REALITY private key."

[[ -n "${PUBLIC_KEY}" ]] ||
    die "Could not extract REALITY public key."

printf '%s\n' "${PRIVATE_KEY}" > "${PRIVATE_KEY_FILE}"
printf '%s\n' "${PUBLIC_KEY}" > "${PUBLIC_KEY_FILE}"

# Short ID.
SHORT_ID="$(openssl rand -hex 8)"

[[ "${SHORT_ID}" =~ ^[0-9a-f]{16}$ ]] ||
    die "Invalid short ID generated."

printf '%s\n' "${SHORT_ID}" > "${SHORT_ID_FILE}"

# All generated files belong to the normal user.
chown "${INSTALL_USER}:${INSTALL_GROUP}" \
    "${UUID_FILE}" \
    "${PRIVATE_KEY_FILE}" \
    "${PUBLIC_KEY_FILE}" \
    "${SHORT_ID_FILE}" \
    "${TARGET_FILE}"

# User-readable/writable, not world-readable.
chmod 600 \
    "${UUID_FILE}" \
    "${PRIVATE_KEY_FILE}" \
    "${PUBLIC_KEY_FILE}" \
    "${SHORT_ID_FILE}" \
    "${TARGET_FILE}"

echo
echo "REALITY key pair generated."
echo "Short ID generated."

# ------------------------------------------------------------
# Backup existing config
# ------------------------------------------------------------

echo
echo "[7/9] Creating Xray configuration..."

mkdir -p "${XRAY_CONFIG_DIR}"

if [[ -f "${XRAY_CONFIG}" ]]; then

    BACKUP_FILE="${BACKUP_DIR}/config-$(date +%Y%m%d-%H%M%S).json"

    cp "${XRAY_CONFIG}" "${BACKUP_FILE}"

    chown "${INSTALL_USER}:${INSTALL_GROUP}" "${BACKUP_FILE}"
    chmod 600 "${BACKUP_FILE}"

    echo "Previous configuration backed up:"
    echo "  ${BACKUP_FILE}"
fi

# ------------------------------------------------------------
# Create Xray config
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

# ------------------------------------------------------------
# Xray systemd permission fix
# ------------------------------------------------------------
#
# Official Xray systemd service normally runs as "nobody".
# Give that service read access to the config while keeping
# the private key inaccessible to normal non-root users.
#

chown root:nogroup "${XRAY_CONFIG}"
chmod 640 "${XRAY_CONFIG}"

# ------------------------------------------------------------
# Validate configuration
# ------------------------------------------------------------

echo
echo "Testing Xray configuration..."

if ! xray run -test -config "${XRAY_CONFIG}"; then
    die "Xray configuration test failed."
fi

echo
echo "Configuration test passed."

# ------------------------------------------------------------
# UFW
# ------------------------------------------------------------

echo
echo "[8/9] Configuring Ubuntu firewall..."

if command -v ufw >/dev/null 2>&1; then

    # SSH
    ufw allow OpenSSH >/dev/null || true

    # Xray
    ufw allow 443/tcp >/dev/null || true

    if ufw status | grep -q "Status: inactive"; then
        ufw --force enable >/dev/null
    fi

    echo
    ufw status
fi

# ------------------------------------------------------------
# Start Xray
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
# Check listener
# ------------------------------------------------------------

echo
echo "Checking TCP 443..."

if ss -lntp | grep -q ':443'; then
    echo "SUCCESS: Xray is listening on TCP 443."
else
    echo "WARNING: TCP 443 is not currently visible."
fi

# ------------------------------------------------------------
# Client info
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

with the public IP of your Azure VM.

The REALITY private key is server-side.
Do NOT share it.

The client uses the REALITY PUBLIC KEY.
============================================================
EOF

# ------------------------------------------------------------
# Server info
# ------------------------------------------------------------

cat > "${SERVER_INFO}" <<EOF
Xray VLESS + REALITY server

Xray:
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

# ------------------------------------------------------------
# Ownership / permissions for generated files
# ------------------------------------------------------------

chown "${INSTALL_USER}:${INSTALL_GROUP}" \
    "${CLIENT_INFO}" \
    "${SERVER_INFO}"

chmod 600 \
    "${CLIENT_INFO}" \
    "${SERVER_INFO}"

# Runtime directory remains fully accessible to the user.
chown -R "${INSTALL_USER}:${INSTALL_GROUP}" "${RUNTIME_DIR}"
chmod 700 "${RUNTIME_DIR}"
chmod 700 "${BACKUP_DIR}"

# Restore secret file permissions after recursive ownership.
chmod 600 \
    "${PRIVATE_KEY_FILE}" \
    "${PUBLIC_KEY_FILE}" \
    "${UUID_FILE}" \
    "${SHORT_ID_FILE}" \
    "${TARGET_FILE}" \
    "${CLIENT_INFO}" \
    "${SERVER_INFO}"

# ------------------------------------------------------------
# Final output
# ------------------------------------------------------------

echo
echo
echo "============================================================"
echo " INSTALLATION COMPLETE"
echo "============================================================"
echo

echo "Xray status:"
systemctl is-active xray

echo
echo "Xray version:"
xray version | head -n 1

echo
echo "Listening:"
ss -lntp | grep ':443' || true

echo
echo "Repository:"
echo "  ${SCRIPT_DIR}"

echo
echo "Runtime:"
echo "  ${RUNTIME_DIR}"

echo
echo "Client information:"
echo "  ${CLIENT_INFO}"

echo
echo "Display client information:"
echo
echo "  cat '${CLIENT_INFO}'"
echo

echo "============================================================"
echo " AZURE NSG"
echo "============================================================"
echo
echo "Make sure Azure allows:"
echo
echo "  TCP 443  ->  Allow"
echo
echo "SSH:"
echo
echo "  TCP 22   ->  Allow"
echo
echo "No 8080 rule is required."
echo

echo "============================================================"
echo " GIT"
echo "============================================================"
echo
echo "runtime/ has been added to .gitignore."
echo
echo "Verify with:"
echo
echo "  git status"
echo

echo "============================================================"
