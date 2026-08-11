# Xray VLESS + REALITY Installer

A lightweight installer for deploying an Xray VLESS + REALITY server on Ubuntu.

## Features

- Installs or updates Xray using the official Xray installation script.
- Configures VLESS with XTLS Vision.
- Configures REALITY over RAW/TCP.
- Uses TCP port `443` by default.
- Generates a UUID, REALITY key pair, and short ID.
- Validates the Xray configuration before starting the service.
- Configures UFW for SSH and TCP 443 when UFW is available.
- Creates local client/server information files.
- Keeps generated credentials outside the tracked source files.

## Requirements

- Ubuntu Linux
- Root/sudo privileges
- A publicly reachable server
- An external firewall/security group that can allow TCP `443`
- SSH access for administration

## Installation

Place these files in a directory:

```text
install-xray.sh
README.md
.gitignore
```

Then run:

```bash
chmod 700 install-xray.sh
sudo ./install-xray.sh
```

The installer asks for a REALITY target hostname.

Press Enter to use:

```text
www.cloudflare.com
```

The installer tests the target before creating the configuration.

## External firewall

Allow inbound TCP:

```text
443
```

Keep SSH (`22`) available only to trusted source addresses where practical.

No additional port is required by the default configuration.

## Generated files

After installation:

```text
runtime/
├── backups/
├── client-info.txt
├── server-info.txt
├── reality-private-key.txt
├── reality-public-key.txt
├── short-id.txt
├── target.txt
└── uuid.txt
```

The `runtime/` directory is excluded by `.gitignore`.

Do not distribute or publish:

```text
reality-private-key.txt
```

The client uses the REALITY public key, not the private key.

## Client configuration

Open:

```bash
cat runtime/client-info.txt
```

Replace:

```text
YOUR_SERVER_PUBLIC_IP
```

with the server's public IP.

The generated VLESS URI can then be imported into a compatible client.

Typical parameters:

```text
Protocol: VLESS
Address: server public IP
Port: 443
Encryption: none
Flow: xtls-rprx-vision
Transport: RAW/TCP
Security: REALITY
Fingerprint: chrome
SNI: generated target hostname
Public key: generated REALITY public key
Short ID: generated short ID
```

## Service management

Check status:

```bash
sudo systemctl status xray --no-pager
```

Restart:

```bash
sudo systemctl restart xray
```

Stop:

```bash
sudo systemctl stop xray
```

Enable at boot:

```bash
sudo systemctl enable xray
```

View logs:

```bash
sudo journalctl -u xray --no-pager -n 100
```

Follow logs:

```bash
sudo journalctl -u xray -f
```

## Configuration validation

The installed configuration is:

```text
/usr/local/etc/xray/config.json
```

Validate it with:

```bash
sudo xray run -test -config /usr/local/etc/xray/config.json
```

Check TCP 443:

```bash
sudo ss -lntp | grep ':443'
```

Running the installer each time creates a new UUID and REALITY key pair. Existing client configurations will therefore need to be updated.


## Security

- Keep the server's private key private.
- Do not publish the `runtime/` directory.
- Restrict SSH access where possible.
- Do not expose temporary HTTP file servers.
- Do not expose unnecessary ports.
- Configure external firewall/security-group rules independently of UFW.
- Use resource/bandwidth monitoring appropriate to your hosting provider.

There is no guarantee that any proxy protocol is undetectable. This project is intended for legitimate private server administration and connectivity.

## Files

```text
.
├── .gitignore
├── LICENSE
├── README.md
└── install-xray.sh
```

## License

Xray is a separate project and is governed by its own license and project terms.
