#!/bin/sh
# Tachyon 1.4.10 dns.uc mTLS patch for DoH. No extra packages.
set -eu

target=/usr/lib/tachyon/singbox/dns.uc
backup=${target}.mtls.bak

die() { echo "ERROR: $*" >&2; exit 1; }
ask() { printf '%s' "$1" >&2; IFS= read -r value; printf '%s' "$value"; }

[ "$(id -u)" = 0 ] || die "run as root"
[ -f "$target" ] || die "not found: $target"
command -v awk >/dev/null 2>&1 || die "awk is not installed"
command -v ucode >/dev/null 2>&1 || die "ucode is not installed"
command -v uci >/dev/null 2>&1 || die "uci is not installed"

echo "Tachyon DoH mTLS setup (Tachyon 1.4.10 source layout)"
domain=$(ask "DNS domain (for example dns.example.net): ")
case "$domain" in ''|.*|*..*|*.[!A-Za-z0-9]|*[!A-Za-z0-9.-]*) die "invalid DNS domain" ;; esac

doh_path=$(ask "DoH path [/api/v1/router-doh]: ")
doh_path=${doh_path:-/api/v1/router-doh}
case "$doh_path" in /*) ;; *) die "DoH path must start with /" ;; esac
[ "$doh_path" != /dns-query ] || die "/dns-query is reserved; enter the server's private DoH path"

client_certificate=$(ask "Client certificate path: ")
client_key=$(ask "Client private-key path: ")
[ -f "$client_certificate" ] || die "certificate not found: $client_certificate"
[ -f "$client_key" ] || die "private key not found: $client_key"
[ -r "$client_certificate" ] && [ -r "$client_key" ] || die "certificate or key is not readable"

endpoint="https://$domain$doh_path"
current_dns_type=$(uci -q get tachyon.settings.dns_type || true)
case "$current_dns_type" in ''|doh) ;; *) die "existing Tachyon DNS type is '$current_dns_type'; nothing changed" ;; esac

if grep -q 'dns_mtls_enabled' "$target" && grep -q 'client_certificate_path' "$target"; then
    echo "Tachyon mTLS patch is already applied."
else
    new_file=$(mktemp)
    trap 'rm -f "$new_file"' EXIT HUP INT TERM

    if ! awk '
function mtls_block() {
    print "        if (mtls_settings != null && bool_option(mtls_settings, \"dns_mtls_enabled\", false)) {"
    print "            let mtls_host = option(mtls_settings, \"dns_mtls_host\", \"\");"
    print "            if (mtls_host != \"\" && server == mtls_host) {"
    print "                let client_certificate = option(mtls_settings, \"dns_mtls_client_certificate\", \"\");"
    print "                let client_key = option(mtls_settings, \"dns_mtls_client_key\", \"\");"
    print "                if (client_certificate != \"\" && client_key != \"\") {"
    print "                    result.tls.client_certificate_path = client_certificate;"
    print "                    result.tls.client_key_path = client_key;"
    print "                }"
    print "            }"
    print "        }"
}
$0 == "function server_from_options(tag_name, dns_type, dns_server, detour) {" {
    print "function server_from_options(tag_name, dns_type, dns_server, detour, mtls_settings) {"; signature++; next
}
$0 == "        result.path = (path != \"\" && path != \"/\") ? path : \"/dns-query\";" {
    print; doh_path++; in_doh=1; next
}
in_doh && $0 == "        result.tls = { enabled: true };" {
    print; mtls_block(); tls++; in_doh=0; next
}
$0 == "        detour" {
    print "        detour,"; print "        settings"; active_call++; next
}
$0 == "function add_health_candidate(result, kind, index_value, server, override_dns_type, override_detour) {" {
    print "function add_health_candidate(result, settings, kind, index_value, server, override_dns_type, override_detour) {"; health_signature++; next
}
$0 == "        ? server_from_options(server_tag, dns_type, server, detour)" {
    print "        ? server_from_options(server_tag, dns_type, server, detour, settings)"; health_call++; next
}
$0 == "                add_health_candidate(result, \"main\", i, state.main_servers[i], dns_type, \"\");" {
    print "                add_health_candidate(result, settings, \"main\", i, state.main_servers[i], dns_type, \"\");"; main_call++; next
}
$0 == "                add_health_candidate(result, \"bootstrap\", i, state.bootstrap_servers[i]);" {
    print "                add_health_candidate(result, settings, \"bootstrap\", i, state.bootstrap_servers[i]);"; bootstrap_call++; next
}
{ print }
END {
    if (signature != 1 || doh_path != 1 || tls != 1 || active_call != 1 || health_signature != 1 || health_call != 1 || main_call != 1 || bootstrap_call != 1)
        exit 1
}
' "$target" >"$new_file"; then
        die "this dns.uc does not match Tachyon 1.4.10 expected source; nothing changed"
    fi

    ucode -c "$new_file" >/dev/null 2>&1 || die "generated dns.uc failed ucode syntax check; nothing changed"
    [ -e "$backup" ] || cp -p "$target" "$backup"
    chmod 644 "$new_file"
    mv "$new_file" "$target"
    trap - EXIT HUP INT TERM
    echo "Tachyon mTLS patch applied. Backup: $backup"
fi

[ -n "$current_dns_type" ] || uci set tachyon.settings.dns_type='doh'
existing_servers=$(uci -q get tachyon.settings.dns_server || true)
uci -q delete tachyon.settings.dns_server || true
uci add_list "tachyon.settings.dns_server=$endpoint"
for server in $existing_servers; do
    server=${server#\'}; server=${server%\'}
    [ "$server" = "$endpoint" ] || uci add_list "tachyon.settings.dns_server=$server"
done
uci set tachyon.settings.dns_mtls_enabled='1'
uci set "tachyon.settings.dns_mtls_host=$domain"
uci set "tachyon.settings.dns_mtls_client_certificate=$client_certificate"
uci set "tachyon.settings.dns_mtls_client_key=$client_key"
uci set "tachyon.settings.dns_mtls_endpoint=$endpoint"
uci commit tachyon

[ -x /etc/init.d/tachyon ] && /etc/init.d/tachyon reload
echo "Tachyon added mTLS DoH: $endpoint"
