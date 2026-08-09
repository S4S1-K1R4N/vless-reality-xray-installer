#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# Xray VLESS + REALITY installer
# Ubuntu 24.04 / Xray stable
# ============================================================

XRAY_CONFIG="/usr/local/etc/xray/config.json"
BACKUP_DIR="/root/xray-backups"
CLIENT_INFO="/root/xray-client.txt"

echo
echo "================================================"
echo " Xray VLESS + REALITY Installer"
echo "================================================"
echo

if [[ "$EUID" -ne 0 ]]; then
    echo "ERROR: Run this script with sudo."
    echo
    echo "Example:"
    echo "  sudo ./install-xray.sh"
    exit 1
fi

# ------------------------------------------------------------
# 1. Ubuntu dependencies
# ------------------------------------------------------------

echo "[1/8] Installing required packages..."

apt-get update
apt-get install -y \
    curl \
    ca-certificates \
    openssl \
    uuid-runtime \
    jq

# ------------------------------------------------------------
# 2. Install/update Xray
# ------------------------------------------------------------

echo
echo "[2/8] Installing/updating Xray..."

bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install

if ! command -v xray >/dev/null 2>&1; then
    echo "ERROR: Xray installation failed."
    exit 1
fi

echo
xray version

# ------------------------------------------------------------
# 3. Choose and test REALITY target
# ------------------------------------------------------------

echo
echo "[3/8] REALITY target"
echo
echo "Enter a normal HTTPS hostname."
echo "The script will test it with:"
echo "  xray tls ping HOST:443"
echo
echo "Press Enter to use www.cloudflare.com."
echo

read -r -p "Target hostname [www.cloudflare.com]: " TARGET

TARGET="${TARGET:-www.cloudflare.com}"

# Remove protocol if accidentally supplied
TARGET="${TARGET#https://}"
TARGET="${TARGET#http://}"

# Remove path
TARGET="${TARGET%%/*}"

# Remove port
TARGET="${TARGET%%:*}"

echo
echo "Testing target:"
echo "  ${TARGET}:443"
echo

if ! xray tls ping "${TARGET}:443"; then
    echo
    echo "ERROR: TLS test failed for ${TARGET}:443"
    echo
    echo "Choose another HTTPS hostname and run the script again."
    exit 1
fi

echo
echo "Target TLS test succeeded."

# ------------------------------------------------------------
# 4. Generate UUID
# ------------------------------------------------------------

echo
echo "[4/8] Generating UUID..."

UUID="$(xray uuid | tr -d '\r\n[:space:]')"

if [[ -z "$UUID" ]]; then
    echo "ERROR: Could not generate UUID."
    exit 1
fi

echo "UUID generated."

# ------------------------------------------------------------
# 5. Generate REALITY X25519 key pair
# ------------------------------------------------------------

echo
echo "[5/8] Generating REALITY X25519 key pair..."

KEY_OUTPUT="$(xray x25519)"

echo
echo "Xray key generator output:"
echo "$KEY_OUTPUT"
echo

# Xray v26.x format:
#
# PrivateKey: ...
# Password (PublicKey): ...
# Hash32: ...
#
PRIVATE_KEY="$(
    printf '%s\n' "$KEY_OUTPUT" |
    sed -n 's/^PrivateKey: //p' |
    head -n 1 |
    tr -d '\r'
)"

PUBLIC_KEY="$(
    printf '%s\n' "$KEY_OUTPUT" |
    sed -n 's/^Password (PublicKey): //p' |
    head -n 1 |
    tr -d '\r'
)"

# Fallback for older Xray output formats
if [[ -z "$PUBLIC_KEY" ]]; then
    PUBLIC_KEY="$(
        printf '%s\n' "$KEY_OUTPUT" |
        sed -n 's/^Password: //p' |
        head -n 1 |
        tr -d '\r'
    )"
fi

if [[ -z "$PUBLIC_KEY" ]]; then
    PUBLIC_KEY="$(
        printf '%s\n' "$KEY_OUTPUT" |
        sed -n 's/^PublicKey: //p' |
        head -n 1 |
        tr -d '\r'
    )"
fi

if [[ -z "$PRIVATE_KEY" ]]; then
    echo "ERROR: Could not extract X25519 private key."
    exit 1
fi

if [[ -z "$PUBLIC_KEY" ]]; then
    echo "ERROR: Could not extract X25519 public key."
    echo
    echo "You can manually obtain it with:"
    echo
    echo "xray x25519 -i \"$PRIVATE_KEY\""
    exit 1
fi

echo "REALITY key pair generated successfully."

# ------------------------------------------------------------
# Generate short ID
# ------------------------------------------------------------

SHORT_ID="$(openssl rand -hex 8)"

if [[ ! "$SHORT_ID" =~ ^[0-9a-f]{16}$ ]]; then
    echo "ERROR: Invalid short ID generated."
    exit 1
fi

echo "Short ID generated."

# ------------------------------------------------------------
# 6. Backup old configuration
# ------------------------------------------------------------

echo
echo "[6/8] Preparing Xray configuration..."

mkdir -p "$BACKUP_DIR"

if [[ -f "$XRAY_CONFIG" ]]; then

    BACKUP_FILE="${BACKUP_DIR}/config-$(date +%Y%m%d-%H%M%S).json"

    cp "$XRAY_CONFIG" "$BACKUP_FILE"

    echo "Existing configuration backed up to:"
    echo "  $BACKUP_FILE"
fi

mkdir -p "$(dirname "$XRAY_CONFIG")"

# ------------------------------------------------------------
# Write configuration
# ------------------------------------------------------------

cat > "$XRAY_CONFIG" <<EOF
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

chmod 600 "$XRAY_CONFIG"

# ------------------------------------------------------------
# Test configuration
# ------------------------------------------------------------

echo
echo "Testing Xray configuration..."

if ! xray run -test -config "$XRAY_CONFIG"; then
    echo
    echo "================================================"
    echo " ERROR: Xray configuration test failed"
    echo "================================================"
    echo
    exit 1
fi

echo
echo "Xray configuration is valid."

# ------------------------------------------------------------
# 7. Configure UFW
# ------------------------------------------------------------

echo
echo "[7/8] Configuring Ubuntu firewall..."

if command -v ufw >/dev/null 2>&1; then

    ufw allow OpenSSH >/dev/null || true
    ufw allow 443/tcp >/dev/null || true

    if ufw status | grep -q "Status: inactive"; then
        ufw --force enable >/dev/null
    fi

    echo
    ufw status
else
    echo "UFW is not installed. Skipping UFW configuration."
fi

# ------------------------------------------------------------
# 8. Start Xray
# ------------------------------------------------------------

echo
echo "[8/8] Starting Xray..."

systemctl daemon-reload
systemctl enable xray
systemctl restart xray

sleep 2

if ! systemctl is-active --quiet xray; then

    echo
    echo "================================================"
    echo " ERROR: Xray failed to start"
    echo "================================================"
    echo

    systemctl --no-pager status xray || true

    echo
    echo "Recent Xray logs:"
    journalctl -u xray --no-pager -n 50 || true

    exit 1
fi

# ------------------------------------------------------------
# Save client information
# ------------------------------------------------------------

echo
echo "Saving client configuration..."

cat > "$CLIENT_INFO" <<EOF
============================================================
Xray VLESS + REALITY CLIENT INFORMATION
============================================================

SERVER ADDRESS:
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

vless://${UUID}@YOUR_AZURE_PUBLIC_IP:443?encryption=none&security=reality&sni=${TARGET}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&flow=xtls-rprx-vision&type=raw#Azure-Xray
============================================================
EOF

chmod 600 "$CLIENT_INFO"

# ------------------------------------------------------------
# Final checks
# ------------------------------------------------------------

echo
echo "Checking port 443..."

if ss -lntp | grep -q ':443'; then
    echo "TCP 443 is listening."
else
    echo "WARNING: Nothing appears to be listening on TCP 443."
fi

echo
echo "============================================================"
echo " INSTALLATION COMPLETE"
echo "============================================================"
echo

echo "Xray service:"
systemctl is-active xray

echo
echo "Xray version:"
xray version

echo
echo "Client configuration saved at:"
echo "  $CLIENT_INFO"

echo
echo "Display client configuration with:"
echo "  sudo cat $CLIENT_INFO"

echo
echo "IMPORTANT:"
echo "1. Azure NSG must allow TCP 443."
echo "2. Replace YOUR_AZURE_PUBLIC_IP in the VLESS URI."
echo "3. Never share the REALITY private key."
echo "4. The client uses the PUBLIC key, not the private key."

echo
echo "============================================================"
