#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# Simple VLESS + REALITY Xray installer for Ubuntu
# Intended for a personal server.
# ============================================================

XRAY_CONFIG="/usr/local/etc/xray/config.json"
BACKUP_DIR="/root/xray-backups"

echo
echo "=============================================="
echo " Xray VLESS + REALITY installer"
echo "=============================================="
echo

if [[ $EUID -ne 0 ]]; then
    echo "Run this script as root."
    exit 1
fi

# ------------------------------------------------------------
# Basic packages
# ------------------------------------------------------------

echo "[1/8] Updating Ubuntu..."

apt-get update
apt-get install -y \
    curl \
    ca-certificates \
    openssl \
    uuid-runtime \
    jq

# ------------------------------------------------------------
# Install Xray using official installer
# ------------------------------------------------------------

echo
echo "[2/8] Installing/updating Xray..."

bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install

if ! command -v xray >/dev/null 2>&1; then
    echo "Xray installation failed."
    exit 1
fi

echo
xray version

# ------------------------------------------------------------
# Ask for target
# ------------------------------------------------------------

echo
echo "[3/8] REALITY target"
echo
echo "Choose a normal HTTPS site that you have verified works"
echo "with: xray tls ping DOMAIN"
echo
read -rp "Target hostname [www.cloudflare.com]: " TARGET

TARGET="${TARGET:-www.cloudflare.com}"

# Remove accidental protocol/path/port
TARGET="${TARGET#https://}"
TARGET="${TARGET#http://}"
TARGET="${TARGET%%/*}"
TARGET="${TARGET%%:*}"

echo
echo "Testing target: ${TARGET}:443"

if ! xray tls ping "${TARGET}:443"; then
    echo
    echo "The target test failed."
    echo "Choose another HTTPS target and run the script again."
    exit 1
fi

# ------------------------------------------------------------
# Generate UUID
# ------------------------------------------------------------

echo
echo "[4/8] Generating UUID..."

UUID="$(xray uuid)"

if [[ -z "${UUID}" ]]; then
    echo "Could not generate UUID."
    exit 1
fi

# ------------------------------------------------------------
# Generate X25519 keys
# ------------------------------------------------------------

echo
echo "[5/8] Generating REALITY X25519 keys..."

KEY_OUTPUT="$(xray x25519)"

PRIVATE_KEY="$(printf '%s\n' "${KEY_OUTPUT}" | awk -F': ' '
    /Private key:/ {print $2}
    /PrivateKey:/ {print $2}
' | head -n1)"

if [[ -z "${PRIVATE_KEY}" ]]; then
    echo
    echo "Could not parse the Xray private key."
    echo
    echo "Xray returned:"
    echo "${KEY_OUTPUT}"
    echo
    echo "Generate the keys manually with:"
    echo "  xray x25519"
    exit 1
fi

PUBLIC_KEY="$(xray x25519 -i "${PRIVATE_KEY}" | awk -F': ' '
    /Password:/ {print $2}
    /Public key:/ {print $2}
    /PublicKey:/ {print $2}
' | head -n1)"

if [[ -z "${PUBLIC_KEY}" ]]; then
    echo
    echo "Could not derive the REALITY public key."
    echo
    echo "Generate it manually with:"
    echo "  xray x25519 -i \"${PRIVATE_KEY}\""
    exit 1
fi

# ------------------------------------------------------------
# Generate short ID
# ------------------------------------------------------------

echo
echo "[6/8] Generating short ID..."

SHORT_ID="$(openssl rand -hex 8)"

# ------------------------------------------------------------
# Backup existing configuration
# ------------------------------------------------------------

mkdir -p "${BACKUP_DIR}"

if [[ -f "${XRAY_CONFIG}" ]]; then
    cp "${XRAY_CONFIG}" \
       "${BACKUP_DIR}/config-$(date +%Y%m%d-%H%M%S).json"
fi

mkdir -p "$(dirname "${XRAY_CONFIG}")"

# ------------------------------------------------------------
# Write Xray configuration
# ------------------------------------------------------------

echo
echo "[7/8] Writing Xray configuration..."

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

chmod 600 "${XRAY_CONFIG}"

# ------------------------------------------------------------
# Test configuration
# ------------------------------------------------------------

echo
echo "Testing configuration..."

if ! xray run -test -config "${XRAY_CONFIG}"; then
    echo
    echo "Xray configuration test FAILED."
    exit 1
fi

# ------------------------------------------------------------
# Firewall
# ------------------------------------------------------------

echo
echo "[8/8] Configuring Ubuntu firewall..."

if command -v ufw >/dev/null 2>&1; then
    ufw allow OpenSSH >/dev/null || true
    ufw allow 443/tcp >/dev/null || true

    # Enable UFW only if it is currently inactive.
    if ufw status | grep -q "Status: inactive"; then
        ufw --force enable >/dev/null
    fi
fi

# ------------------------------------------------------------
# Start Xray
# ------------------------------------------------------------

systemctl daemon-reload
systemctl enable xray
systemctl restart xray

sleep 2

if ! systemctl is-active --quiet xray; then
    echo
    echo "Xray failed to start."
    echo
    journalctl -u xray --no-pager -n 50
    exit 1
fi

# ------------------------------------------------------------
# Save client information
# ------------------------------------------------------------

INFO_FILE="/root/xray-client.txt"

cat > "${INFO_FILE}" <<EOF
Xray VLESS + REALITY
====================

Server address:
YOUR_AZURE_PUBLIC_IP

Port:
443

Protocol:
VLESS

UUID:
${UUID}

Flow:
xtls-rprx-vision

Transport:
RAW/TCP

Security:
REALITY

SNI / Server Name:
${TARGET}

Fingerprint:
chrome

Public Key:
${PUBLIC_KEY}

Short ID:
${SHORT_ID}

Target:
${TARGET}:443

VLESS URI template:
vless://${UUID}@YOUR_AZURE_PUBLIC_IP:443?encryption=none&security=reality&sni=${TARGET}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&flow=xtls-rprx-vision&type=tcp#Azure-Xray
EOF

chmod 600 "${INFO_FILE}"

# ------------------------------------------------------------
# Final output
# ------------------------------------------------------------

echo
echo
echo "=============================================="
echo " INSTALLATION COMPLETE"
echo "=============================================="
echo
echo "Xray status:"
systemctl --no-pager --full status xray | head -n 12
echo
echo "Listening ports:"
ss -lntp | grep ':443' || true
echo
echo "Client information saved to:"
echo "  ${INFO_FILE}"
echo
echo "Show client information with:"
echo "  cat ${INFO_FILE}"
echo
echo "IMPORTANT:"
echo "Replace YOUR_AZURE_PUBLIC_IP in the client information"
echo "with your VM's actual public IP."
echo
echo "Azure NSG must allow TCP 443."
echo
