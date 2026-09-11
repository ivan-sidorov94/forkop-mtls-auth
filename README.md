# Forkop DoH with Nginx, AdGuard Home, and mTLS

[Русская версия](README.ru.md)

This guide creates a private DNS-over-HTTPS endpoint for an OpenWrt router.
Only routers with a client certificate issued by the server CA can use it.

> [!WARNING]
> This project changes DNS and TLS settings on a router and server. Test it on
> equipment you administer, keep the generated CA private key on the server,
> and read the rollback section before changing a production router.

## What is created

```text
OpenWrt Forkop -- mTLS DoH --> Nginx :443 --> AdGuard Home :3001 (loopback)
```

The public TLS certificate is managed by Let’s Encrypt.  The separate mTLS CA
issues and revokes router certificates.

## Repository contents

| File | Purpose |
| --- | --- |
| `forkop-doh-server.sh` | Interactive Debian/Ubuntu server installer and certificate manager. |
| `forkop-mtls-patch.sh` | Interactive OpenWrt Forkop mTLS setup. |
| `forkop-mtls-reset.sh` | OpenWrt mTLS rollback script. |
| `AdGuardHome.yaml.example` | Minimal AdGuard Home configuration template. |
| `README.ru.md` | Complete Russian guide. |

## Quick start

1. Point a domain such as `dns.example.net` to a new Debian/Ubuntu server and
   open TCP ports 80 and 443.
2. Copy this repository to the server and run `./forkop-doh-server.sh` as
   `root`; choose menu item `1`.
3. Copy an AdGuard Home YAML file to `/opt/AdGuardHome/AdGuardHome.yaml` when
   the installer pauses.
4. Use menu item `2` to issue a router certificate, then run
   `forkop-mtls-patch.sh` on OpenWrt.

The detailed steps, validation, certificate revocation, and rollback follow
below.

## Requirements

- A new Debian or Ubuntu server with systemd and public ports 80 and 443.
- A DNS `A`/`AAAA` record for the chosen name, for example `dns.example.net`,
  pointing to that server before running the server setup.
- An OpenWrt router with Forkop already installed.
- SSH access as `root` to both systems.

Server setup is intended for a fresh installation. Do not run it on a server
where the same domain’s Nginx site or an AdGuard Home installation that must be
preserved already exists.

## 1. Prepare the three files

Copy these files to the server, for example to `/root/forkop-doh/`:

```text
forkop-doh-server.sh
AdGuardHome.yaml.example
forkop-mtls-patch.sh
forkop-mtls-reset.sh
```

`AdGuardHome.yaml.example` is a safe minimal starting point.  If an existing
AdGuard Home configuration is already known to work, use that file instead;
it preserves filters and local users.

## 2. Configure the server

On the server:

```bash
cd /root/forkop-doh
chmod 700 forkop-doh-server.sh
./forkop-doh-server.sh
```

The installer itself installs Nginx, Certbot, AdGuard Home, and OpenSSL.  No
separate Nginx installation or configuration command is required.

If setup is interrupted after the domain has been entered, run the script
again and choose `1`; it resumes the unfinished installation.

Choose `1`, then enter values such as:

```text
DNS domain: dns.example.net
DoH path: /api/v1/router-doh
Email: admin@example.net
```

After AdGuard Home is downloaded, the script pauses.  In a second SSH session,
place your prepared configuration in its installed directory:

```bash
cp /root/forkop-doh/AdGuardHome.yaml.example /opt/AdGuardHome/AdGuardHome.yaml
chmod 600 /opt/AdGuardHome/AdGuardHome.yaml
```

Edit the example first or copy your own existing `AdGuardHome.yaml` instead.
Return to the first session and press Enter.  The script never asks for or
copies the YAML file itself.

Use a unique, unguessable DoH path.  It is not the access control mechanism;
mTLS is.  The script creates:

```text
/etc/nginx/sites-available/dns.example.net.conf
/etc/nginx/sites-enabled/dns.example.net.conf
/etc/forkop-doh/pki/                 # CA private key and certificate database
/etc/forkop-doh/clients/             # issued router credentials
```

It also enables Certbot’s timer and an Nginx reload hook.  Let’s Encrypt
renewals therefore require that port 80 and the domain’s DNS record remain
available.

Opening the domain in a browser shows a static ShareFlow stub page.  It is
saved as `/var/www/DOMAIN/index.html`; it has no file-upload backend.
For an already configured server, choose menu item `5` to create or update the
Nginx site and stub page.

AdGuard Home is intentionally available only at `127.0.0.1:3001`.  To open
its local dashboard from an administrator computer, create an SSH tunnel:

```bash
ssh -L 3001:127.0.0.1:3001 root@SERVER_IP
```

Then open `http://127.0.0.1:3001` locally.

## 3. Issue a router certificate

On the server, choose a unique router name:

```bash
./forkop-doh-server.sh
```

Choose `2` and enter `openwrt-home`.

The command prints the two files to copy.  Copy them to the router; replace
`ROUTER_IP` and `openwrt-home` with the selected values:

```bash
ssh root@ROUTER_IP 'mkdir -p /etc/forkop/dns && chmod 700 /etc/forkop/dns'
scp /etc/forkop-doh/clients/openwrt-home/client.crt root@ROUTER_IP:/etc/forkop/dns/client.crt
scp /etc/forkop-doh/clients/openwrt-home/client.key root@ROUTER_IP:/etc/forkop/dns/client.key
ssh root@ROUTER_IP 'chmod 644 /etc/forkop/dns/client.crt && chmod 600 /etc/forkop/dns/client.key'
scp forkop-mtls-patch.sh root@ROUTER_IP:/root/forkop-mtls-patch.sh
```

The client key is secret.  Never copy `/etc/forkop-doh/pki/private/ca.key` off
the server.

## 4. Configure Forkop

Copy `forkop-mtls-patch.sh` to the router, then run it as root:

```sh
chmod 700 /root/forkop-mtls-patch.sh
/root/forkop-mtls-patch.sh
```

Answer using the same server values:

```text
DNS domain: dns.example.net
DoH path: /api/v1/router-doh
Client certificate path: /etc/forkop/dns/client.crt
Client private-key path: /etc/forkop/dns/client.key
```

The router script applies the required Forkop `dns.uc` change, creates one
backup at `/usr/lib/forkop/singbox/dns.uc.mtls.bak`, writes the Forkop UCI
settings, and reloads Forkop.  It adds the new mTLS endpoint first, then keeps
all existing main DNS entries after it in their original order.  Forkop uses one DNS protocol for the whole list:
the existing `dns_type` must already be `doh`, otherwise the script stops
without changing anything.  It uses BusyBox tools only and installs no
packages.  Running the script again with the same values safely repairs
accidental single quotes in older DNS entries.

## 5. Verify

On the server:

```bash
systemctl status nginx adguardhome --no-pager
nginx -t
```

On OpenWrt:

```sh
uci show forkop.settings | grep -E 'dns_(server|type|mtls)'
logread | grep -Ei 'forkop|sing-box|dns|tls' | tail -30
```

The generated Forkop configuration must point to
`https://dns.example.net/api/v1/router-doh` and contain the two client-key
paths in its TLS section.

## 6. Add or revoke routers

```bash
# On the server
./forkop-doh-server.sh
```

Choose `2`, `3`, or `4`.  Revocation regenerates the CRL and reloads Nginx immediately.  The revoked
router loses DoH access; remove its local certificate and key separately if
the router is still under your control.

## Renewing a router certificate

Router client certificates are valid for **825 days**. They are issued by the
private mTLS CA, not by Let’s Encrypt, and are therefore not renewed
automatically. The public Nginx certificate is renewed automatically by
Certbot; this is separate from router certificates.

To renew without DNS downtime:

1. Issue a new certificate under a new name, such as `openwrt-home-2028`.
2. Copy its `client.crt` and `client.key` to the router over the existing
   files, preserving permissions `644` and `600` respectively.
3. Reload Forkop and verify that the router resolves DNS through the DoH
   endpoint.
4. Revoke the old client certificate through server menu item `3`.

## Updating Forkop

Forkop updates may replace `dns.uc`.  If that happens, run
`/root/forkop-mtls-patch.sh` again on the router.  It stops without changing
anything if its expected Forkop source version no longer matches.

## Remove mTLS from a router

To return a previously customized router to ordinary Forkop before testing a
new installation, copy and run `forkop-mtls-reset.sh` as root:

```sh
chmod 700 /root/forkop-mtls-reset.sh
/root/forkop-mtls-reset.sh
```

It restores an unpatched `dns.uc` from either `dns.uc.mtls.bak` or `dns.uc.bak`,
removes only the mTLS UCI fields, credentials, patch-recovery service, and
patch files, then reloads Forkop.  It stops without changing anything if a
valid unpatched backup is not present.
