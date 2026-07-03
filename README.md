# Fluxus UI / FluxChat Relay Server

Fluxus UI is the Ubuntu VPS relay package for FluxChat.

It installs:

- `FluxChat.Server` - the relay server on TCP `42800`;
- `fluxus` - the server admin menu for invites, users, bans, tokens, and offline queues;
- a `systemd` service named `fluxchat`;
- persistent server data in `/var/lib/fluxchat`.

## Quick Install / Update

Run this on your Ubuntu VPS as `root`:

```bash
bash <(curl -Ls https://raw.githubusercontent.com/avov53/fluxusui/main/install.sh)
```

The same command is used for updates. It replaces only the server binaries and service file.

It does **not** delete:

- `/var/lib/fluxchat/fluxchat.db`
- users
- invite history
- saved tokens
- bans
- offline pending messages

## Create Invite Codes

After installation, open the admin menu:

```bash
fluxus
```

Choose:

```text
1. Create invite code
```

Send the generated invite code to your friend. They enter it in FluxChat in the `Invite / token` field.

After first login, FluxChat saves a permanent token automatically. The invite code is one-time-use.

## Client Connection

In FluxChat:

```text
Mode: VPS
Server: YOUR_VPS_IP:42800
Invite / token: invite code from fluxus
```

## Service Commands

```bash
systemctl status fluxchat
systemctl restart fluxchat
journalctl -u fluxchat -f
```

## Full Uninstall

This removes the service, binaries, firewall rule, and all server data:

```bash
sudo systemctl disable --now fluxchat
sudo rm -f /etc/systemd/system/fluxchat.service
sudo rm -rf /opt/fluxchat
sudo rm -f /usr/local/bin/fluxus
sudo rm -rf /var/lib/fluxchat
sudo systemctl daemon-reload
sudo ufw delete allow 42800/tcp
```

## Notes

- The repository must be public for the `curl` installer command to work.
- The installer is designed for Ubuntu VPS servers.
- The relay server does not require inbound ports on client PCs. Only the VPS needs TCP `42800` open.
