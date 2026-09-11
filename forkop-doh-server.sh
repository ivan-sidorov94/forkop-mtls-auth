#!/usr/bin/env bash
# Debian/Ubuntu: Nginx + AdGuard Home + mTLS client-CA manager for Forkop DoH.

set -euo pipefail
umask 077

root=/etc/forkop-doh
pki=$root/pki
clients=$root/clients
env_file=$root/server.env
setup_complete=$root/setup.complete
nginx_mtls=/etc/nginx/mtls
nginx_site=
adguard_config=/opt/AdGuardHome/AdGuardHome.yaml

die() { echo "ERROR: $*" >&2; exit 1; }
need_root() { [ "$(id -u)" = 0 ] || die "run as root"; }
valid_name() { [[ $1 =~ ^[A-Za-z0-9._-]+$ ]]; }
valid_domain() { [[ $1 =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]]; }

load_config() {
    [ -f "$env_file" ] || die "run: $0 setup"
    # shellcheck disable=SC1090
    . "$env_file"
}

write_ca_config() {
    cat >"$pki/openssl.cnf" <<EOF
[ ca ]
default_ca = CA_default
[ CA_default ]
dir = $pki
database = \$dir/index.txt
new_certs_dir = \$dir/newcerts
certificate = \$dir/ca.crt
private_key = \$dir/private/ca.key
serial = \$dir/serial
crlnumber = \$dir/crlnumber
default_md = sha256
default_days = 825
default_crl_days = 30
policy = policy_any
x509_extensions = client_cert
[ policy_any ]
commonName = supplied
[ client_cert ]
basicConstraints = critical,CA:FALSE
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,clientAuth
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid,issuer
EOF
}

install_adguard() {
    [ -x /opt/AdGuardHome/AdGuardHome ] && return

    local arch archive
    case "$(uname -m)" in
        x86_64) arch=amd64 ;;
        aarch64|arm64) arch=arm64 ;;
        *) die "unsupported architecture: $(uname -m)" ;;
    esac
    archive=/tmp/AdGuardHome.tar.gz
    curl -fsSL "https://github.com/AdguardTeam/AdGuardHome/releases/latest/download/AdGuardHome_linux_${arch}.tar.gz" -o "$archive"
    tar -xzf "$archive" -C /opt
    rm -f "$archive"
}

write_adguard_config() {
    [ -f "$adguard_config" ] || die "AdGuard config not found: $adguard_config"

    cat >/etc/systemd/system/adguardhome.service <<EOF
[Unit]
Description=AdGuard Home
After=network-online.target
Wants=network-online.target
[Service]
ExecStart=/opt/AdGuardHome/AdGuardHome -c $adguard_config -w /opt/AdGuardHome
Restart=on-failure
[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl reset-failed adguardhome 2>/dev/null || true
    systemctl enable --now adguardhome
}

sync_ca() {
    install -d -m 755 "$nginx_mtls"
    install -m 644 "$pki/ca.crt" "$nginx_mtls/forkop-client-ca.crt"
    install -m 644 "$pki/crl/ca.crl.pem" "$nginx_mtls/forkop-client-ca.crl.pem"
}

write_nginx_config() {
    local stub_root="/var/www/$DOMAIN"
    install -d -m 755 "$stub_root"
    if [ ! -e "$stub_root/index.html" ] || \
       grep -qE '<title>Service available</title>|<!-- Forkop stub -->' "$stub_root/index.html"; then
        cat >"$stub_root/index.html" <<'EOF'
<!doctype html>
<!-- Forkop stub -->
<html lang="ru">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>ShareFlow — Файлообменник</title>
<link href="https://fonts.googleapis.com/css2?family=Inter:wght@400;600&display=swap" rel="stylesheet">
<style>
  * { box-sizing: border-box; }
  body { font-family: Inter, sans-serif; background: linear-gradient(-45deg, #ee7752, #e73c7e, #23a6d5, #23d5ab); background-size: 400% 400%; animation: gradient 15s ease infinite; min-height: 100vh; margin: 0; display: flex; justify-content: center; align-items: center; padding: 1rem; }
  @keyframes gradient { 0%, 100% { background-position: 0% 50%; } 50% { background-position: 100% 50%; } }
  main { background: rgba(255,255,255,.95); padding: 2.5rem; border-radius: 1.5rem; box-shadow: 0 20px 40px rgba(0,0,0,.15); width: 100%; max-width: 28rem; text-align: center; }
  h1 { margin: 0 0 .6rem; color: #1f2937; font-size: 1.75rem; }
  p { color: #6b7280; margin: 0 0 1.8rem; font-size: .95rem; }
  #drop-zone { border: 2px dashed #d1d5db; border-radius: 1rem; padding: 3rem 1.25rem; background: #f9fafb; cursor: pointer; transition: .2s; margin-bottom: 1.5rem; }
  #drop-zone.active, #drop-zone:hover { border-color: #3b82f6; background: #eff6ff; }
  .icon { font-size: 2.5rem; margin-bottom: .9rem; }
  .label { color: #4b5563; font-weight: 600; }.hint { color: #9ca3af; font-size: .8rem; margin-top: .35rem; }
  button { background: #3b82f6; color: #fff; border: 0; padding: .9rem 1.5rem; width: 100%; border-radius: .75rem; font: 600 1rem Inter, sans-serif; cursor: pointer; } button:hover { background: #2563eb; }
  #file-input { display: none; }
</style>
</head>
<body>
<main>
  <h1>ShareFlow</h1>
  <p>Безопасный и быстрый обмен файлами</p>
  <div id="drop-zone" role="button" tabindex="0">
    <div class="icon">☁️</div><div class="label">Перетащите файлы сюда</div><div class="hint">или нажмите, чтобы выбрать на устройстве</div>
  </div>
  <input type="file" id="file-input" multiple>
  <button type="button" id="upload">Загрузить файлы</button>
</main>
<script>
  const zone = document.querySelector('#drop-zone');
  const input = document.querySelector('#file-input');
  const select = () => input.click();
  const show = files => files.length && alert(`Выбрано файлов: ${files.length}. Загрузка на сервер не настроена.`);
  zone.addEventListener('click', select);
  zone.addEventListener('keydown', event => { if (event.key === 'Enter' || event.key === ' ') select(); });
  zone.addEventListener('dragover', event => { event.preventDefault(); zone.classList.add('active'); });
  zone.addEventListener('dragleave', () => zone.classList.remove('active'));
  zone.addEventListener('drop', event => { event.preventDefault(); zone.classList.remove('active'); show(event.dataTransfer.files); });
  input.addEventListener('change', () => show(input.files));
  document.querySelector('#upload').addEventListener('click', () => show(input.files));
</script>
</body>
</html>
EOF
        chmod 644 "$stub_root/index.html"
    fi

    cat >"$nginx_site" <<EOF
server {
    listen 80;
    server_name $DOMAIN;
    location ^~ /.well-known/acme-challenge/ { root /var/www/acme; }
    location / {
        root $stub_root;
        index index.html;
        try_files \$uri \$uri/ /index.html;
    }
}
EOF
    ln -sfn "$nginx_site" "/etc/nginx/sites-enabled/$DOMAIN.conf"
    install -d -m 755 /var/www/acme
    nginx -t
    systemctl reload nginx

    certbot certonly --webroot -w /var/www/acme -d "$DOMAIN" \
        --email "$EMAIL" --agree-tos --non-interactive --keep-until-expiring

    cat >"$nginx_site" <<EOF
server {
    listen 80;
    server_name $DOMAIN;
    location ^~ /.well-known/acme-challenge/ { root /var/www/acme; }
    location / { return 301 https://\$host\$request_uri; }
}

server {
    listen 443 ssl http2;
    server_name $DOMAIN;

    client_max_body_size 10m;

    ssl_certificate     /etc/letsencrypt/live/$DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$DOMAIN/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;

    ssl_client_certificate $nginx_mtls/forkop-client-ca.crt;
    ssl_crl $nginx_mtls/forkop-client-ca.crl.pem;
    ssl_verify_client optional;
    ssl_verify_depth 1;

    location = /dns-query { return 444; }

    location = $DOH_PATH {
        if (\$ssl_client_verify != SUCCESS) { return 403; }

        proxy_pass http://127.0.0.1:3001/dns-query;
        proxy_http_version 1.1;
        proxy_set_header Connection "";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_buffering off;
    }

    location / {
        root $stub_root;
        index index.html;
        try_files \$uri \$uri/ /index.html;
    }
}
EOF
    install -d -m 755 /etc/letsencrypt/renewal-hooks/deploy
    cat >/etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh <<'EOF'
#!/bin/sh
systemctl reload nginx
EOF
    chmod 755 /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh
    nginx -t
    systemctl reload nginx
}

complete_setup() {
    install_adguard
    while [ ! -f "$adguard_config" ]; do
        echo "Copy your AdGuardHome.yaml to: $adguard_config"
        read -rp 'Press Enter after copying the file: '
    done
    write_adguard_config
    sync_ca
    write_nginx_config
    systemctl enable --now certbot.timer 2>/dev/null || true
    : >"$setup_complete"
    echo "Ready: https://$DOMAIN$DOH_PATH"
    echo "Add a router certificate: $0 add-client openwrt-router"
}

setup() {
    need_root
    command -v apt-get >/dev/null || die "this script supports Debian/Ubuntu only"

    if [ -e "$env_file" ]; then
        load_config
        nginx_site="/etc/nginx/sites-available/$DOMAIN.conf"
        [ ! -e "$setup_complete" ] || die "already configured; use add-client or revoke-client"
        echo "Resuming incomplete setup for $DOMAIN"
        DEBIAN_FRONTEND=noninteractive apt-get \
            -o Dpkg::Options::="--force-confmiss" \
            install -y nginx certbot curl openssl ca-certificates tar
        complete_setup
        return
    fi

    read -rp 'DNS domain (for example dns.example.net): ' DOMAIN
    valid_domain "$DOMAIN" || die "invalid domain"
    nginx_site="/etc/nginx/sites-available/$DOMAIN.conf"
    read -rp 'DoH path (for example /api/v1/my-secret): ' DOH_PATH
    [[ $DOH_PATH =~ ^/[A-Za-z0-9._~/-]+$ ]] || die "invalid DoH path"
    read -rp 'Email for Let\x27s Encrypt: ' EMAIL
    [[ $EMAIL =~ ^[A-Za-z0-9._%+@-]+$ && $EMAIL == *'@'* ]] || die "invalid email"

    [ ! -e "$nginx_site" ] || die "existing Nginx config found: $nginx_site"

    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get \
        -o Dpkg::Options::="--force-confmiss" \
        install -y nginx certbot curl openssl ca-certificates tar

    install -d -m 700 "$pki/private" "$pki/newcerts" "$pki/crl" "$clients"
    : >"$pki/index.txt"
    echo 1000 >"$pki/serial"
    echo 1000 >"$pki/crlnumber"
    write_ca_config
    openssl genrsa -out "$pki/private/ca.key" 4096
    openssl req -x509 -new -key "$pki/private/ca.key" -sha256 -days 3650 \
        -out "$pki/ca.crt" -subj '/CN=Forkop DNS Client CA' \
        -addext 'basicConstraints=critical,CA:TRUE,pathlen:0' \
        -addext 'keyUsage=critical,keyCertSign,cRLSign'
    openssl ca -config "$pki/openssl.cnf" -gencrl -out "$pki/crl/ca.crl.pem"

    printf 'DOMAIN=%q\nDOH_PATH=%q\nEMAIL=%q\n' "$DOMAIN" "$DOH_PATH" "$EMAIL" >"$env_file"
    chmod 600 "$env_file"

    complete_setup
}

add_client() {
    need_root; load_config
    local name=${1:-}
    valid_name "$name" || die "usage: $0 add-client NAME"
    [ ! -e "$clients/$name" ] || die "client already exists: $name"
    install -d -m 700 "$clients/$name"
    openssl genrsa -out "$clients/$name/client.key" 2048
    openssl req -new -key "$clients/$name/client.key" -out "$clients/$name/client.csr" -subj "/CN=$name"
    openssl ca -batch -notext -config "$pki/openssl.cnf" -extensions client_cert \
        -in "$clients/$name/client.csr" -out "$clients/$name/client.crt"
    rm -f "$clients/$name/client.csr"
    chmod 600 "$clients/$name/client.key"
    chmod 644 "$clients/$name/client.crt"
    echo "Certificate: $clients/$name/client.crt"
    echo "Private key:  $clients/$name/client.key"
}

revoke_client() {
    need_root; load_config
    local name=${1:-} cert="$clients/${1:-}/client.crt"
    valid_name "$name" || die "usage: $0 revoke-client NAME"
    [ -f "$cert" ] || die "client certificate not found: $name"
    openssl ca -config "$pki/openssl.cnf" -revoke "$cert" -crl_reason keyCompromise
    openssl ca -config "$pki/openssl.cnf" -gencrl -out "$pki/crl/ca.crl.pem"
    sync_ca
    nginx -t && systemctl reload nginx
    rm -rf "$clients/$name"
    echo "Client revoked: $name"
}

list_clients() {
    need_root; load_config
    openssl crl -in "$pki/crl/ca.crl.pem" -noout >/dev/null
    awk -F '\t' '{print $1, $4, $6}' "$pki/index.txt"
}

update_nginx() {
    need_root; load_config
    nginx_site="/etc/nginx/sites-available/$DOMAIN.conf"
    [ -f "$pki/ca.crt" ] || die "CA not found; complete setup first"
    [ -f "$pki/crl/ca.crl.pem" ] || die "CRL not found; complete setup first"
    sync_ca
    write_nginx_config
    echo "Nginx site and stub page updated."
}

main_menu() {
    need_root
    while :; do
        cat <<'EOF'

Forkop DoH server
1) Install and configure server
2) Add router certificate
3) Revoke router certificate
4) List certificates
5) Update Nginx site and stub page
0) Exit
EOF
        read -rp 'Select: ' action
        case "$action" in
            1) setup ;;
            2) read -rp 'Router name: ' name; add_client "$name" ;;
            3) read -rp 'Router name: ' name; revoke_client "$name" ;;
            4) list_clients ;;
            5) update_nginx ;;
            0) exit 0 ;;
            *) echo "Invalid selection" ;;
        esac
    done
}

case "${1:-}" in
    '') main_menu ;;
    setup) setup ;;
    add-client) add_client "${2:-}" ;;
    revoke-client) revoke_client "${2:-}" ;;
    list-clients) list_clients ;;
    update-nginx) update_nginx ;;
    *) echo "Usage: $0 {setup|add-client NAME|revoke-client NAME|list-clients|update-nginx}" >&2; exit 1 ;;
esac
