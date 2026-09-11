#!/bin/sh
# Removes only the Forkop mTLS customization; the Forkop package remains installed.

set -eu

target=/usr/lib/forkop/singbox/dns.uc
backup=

package_version() {
    opkg status forkop 2>/dev/null | awk '$1 == "Version:" { print $2; exit }'
}

die() {
    echo "ERROR: $*" >&2
    exit 1
}

is_unpatched() {
    ! grep -qE 'dns_mtls_enabled|client_certificate_path|client_key_path' "$1"
}

[ "$(id -u)" = 0 ] || die "run as root"
[ -f "$target" ] || die "not found: $target"
command -v ucode >/dev/null 2>&1 || die "ucode is not installed"
command -v uci >/dev/null 2>&1 || die "uci is not installed"
version=$(package_version)
[ -n "$version" ] || die "Forkop package version not found"

for candidate in "$target.mtls.bak" "$target.bak"; do
    if [ -f "$candidate" ] && [ "$(cat "$candidate.version" 2>/dev/null || true)" = "$version" ] && is_unpatched "$candidate" && ucode -c "$candidate" >/dev/null 2>&1; then
        backup=$candidate
        break
    fi
done

[ -n "$backup" ] || die "no valid unpatched backup found; dns.uc was not changed"

printf '%s' 'Type RESET to remove Forkop mTLS files and settings: '
IFS= read -r confirm
[ "$confirm" = RESET ] || die "cancelled"

[ ! -x /etc/init.d/forkop-mtls ] || /etc/init.d/forkop-mtls stop 2>/dev/null || true
[ ! -x /etc/init.d/forkop-mtls ] || /etc/init.d/forkop-mtls disable 2>/dev/null || true

cp -p "$backup" "$target"

uci -q delete forkop.settings.dns_mtls_enabled || true
uci -q delete forkop.settings.dns_mtls_host || true
uci -q delete forkop.settings.dns_mtls_client_certificate || true
uci -q delete forkop.settings.dns_mtls_client_key || true
endpoint=$(uci -q get forkop.settings.dns_mtls_endpoint || true)
[ -z "$endpoint" ] || uci -q del_list "forkop.settings.dns_server=$endpoint" || true
uci -q delete forkop.settings.dns_mtls_endpoint || true
uci commit forkop

rm -f /etc/init.d/forkop-mtls /usr/sbin/forkop-mtls-patch
rm -f /root/forkop-dns-mtls.patch /tmp/forkop-mtls.state /tmp/forkop-mtls-patch.log
rm -rf /root/forkop-mtls-backups
rm -f "$target.mtls.bak" "$target.mtls.bak.version" "$target.bak" "$target.bak.version" /root/dns.uc.mtls.before-rollback

/etc/init.d/forkop reload

echo "Forkop mTLS customization removed; client certificate files were left in place."
