#!/bin/sh
# Applies mTLS support for DoH without installing extra packages.

set -eu

target=/usr/lib/forkop/singbox/dns.uc
backup=${target}.mtls.bak

die() {
    echo "ERROR: $*" >&2
    exit 1
}

ask() {
    prompt=$1
    value=
    printf '%s' "$prompt" >&2
    IFS= read -r value
    printf '%s' "$value"
}

[ "$(id -u)" = 0 ] || die "run as root"
[ -f "$target" ] || die "not found: $target"
command -v awk >/dev/null 2>&1 || die "awk is not installed"
command -v ucode >/dev/null 2>&1 || die "ucode is not installed"
command -v uci >/dev/null 2>&1 || die "uci is not installed"

echo "Forkop DoH mTLS setup"
domain=$(ask "DNS domain (for example dns.example.net): ")
case "$domain" in
    ''|*[!A-Za-z0-9.-]*) die "invalid DNS domain" ;;
esac

doh_path=$(ask "DoH path [/api/v1/router-doh]: ")
doh_path=${doh_path:-/api/v1/router-doh}
case "$doh_path" in
    /*) ;;
    *) die "DoH path must start with /" ;;
esac
[ "$doh_path" != /dns-query ] || die "/dns-query is reserved; enter the secret path configured on the server"

client_certificate=$(ask "Client certificate path: ")
client_key=$(ask "Client private-key path: ")
[ -f "$client_certificate" ] || die "certificate not found: $client_certificate"
[ -f "$client_key" ] || die "private key not found: $client_key"

endpoint="https://$domain$doh_path"
current_dns_type=$(uci -q get forkop.settings.dns_type || true)
case "$current_dns_type" in
    ''|doh) ;;
    *) die "existing Forkop DNS type is '$current_dns_type'; mixed DNS types are unsupported, nothing changed" ;;
esac

if grep -q 'client_certificate_path' "$target" && \
   grep -q 'client_key_path' "$target" && \
   grep -q 'dns_mtls_enabled' "$target"; then
    echo "Forkop mTLS patch is already applied."
else
    new_file=$(mktemp)
    trap 'rm -f "$new_file"' EXIT HUP INT TERM

    if ! awk '
function tls_block() {
    print ""
    print "        if (mtls_settings != null &&"
    print "            bool_option(mtls_settings, \"dns_mtls_enabled\", false)) {"
    print ""
    print "            let mtls_host = option(mtls_settings, \"dns_mtls_host\", \"\");"
    print ""
    print "            if (mtls_host != \"\" && server == mtls_host) {"
    print "                let client_certificate = option(mtls_settings, \"dns_mtls_client_certificate\", \"\");"
    print "                let client_key = option(mtls_settings, \"dns_mtls_client_key\", \"\");"
    print ""
    print "                if (client_certificate != \"\" && client_key != \"\") {"
    print "                    result.tls = {"
    print "                        enabled: true,"
    print "                        server_name: mtls_host,"
    print "                        client_certificate_path: client_certificate,"
    print "                        client_key_path: client_key"
    print "                    };"
    print "                }"
    print "            }"
    print "        }"
}
$0 == "function server_from_options(tag_name, dns_type, dns_server, detour) {" {
    print "function server_from_options(tag_name, dns_type, dns_server, detour, mtls_settings) {"; signature++; next
}
$0 == "            result.path = path;" {
    print; tls_block(); path++; next
}
$0 == "        active.state.dns_detour" {
    print "        active.state.dns_detour,"; print "        settings"; active++; next
}
$0 == "function add_health_candidate(result, kind, index_value, server) {" {
    print "function add_health_candidate(result, settings, kind, index_value, server) {"; health_signature++; next
}
$0 == "        ? server_from_options(server_tag, result.state.dns_type, server, result.state.dns_detour)" {
    print "        ? server_from_options("
    print "            server_tag,"
    print "            result.state.dns_type,"
    print "            server,"
    print "            result.state.dns_detour,"
    print "            settings"
    print "        )"
    health_call++; next
}
$0 == "            add_health_candidate(result, \"main\", i, state.main_servers[i]);" {
    print "            add_health_candidate(result, settings, \"main\", i, state.main_servers[i]);"; main++; next
}
$0 == "            add_health_candidate(result, \"bootstrap\", i, state.bootstrap_servers[i]);" {
    print "            add_health_candidate(result, settings, \"bootstrap\", i, state.bootstrap_servers[i]);"; bootstrap++; next
}
{ print }
END {
    if (signature != 1 || path != 1 || active != 1 || health_signature != 1 || health_call != 1 || main != 1 || bootstrap != 1)
        exit 1
}
' "$target" >"$new_file"; then
        die "this Forkop dns.uc version does not match the expected source; nothing changed"
    fi

    if ! ucode -c "$new_file" >/dev/null 2>&1; then
        die "generated dns.uc failed the ucode syntax check; nothing changed"
    fi

    [ -e "$backup" ] || cp -p "$target" "$backup"
    chmod 644 "$new_file"
    mv "$new_file" "$target"
    trap - EXIT HUP INT TERM

    echo "Forkop mTLS patch applied. Backup: $backup"
fi

if [ -z "$current_dns_type" ]; then
    uci set forkop.settings.dns_type='doh'
fi

existing_servers=$(uci -q get forkop.settings.dns_server || true)

uci -q delete forkop.settings.dns_server || true
uci add_list "forkop.settings.dns_server=$endpoint"
for server in $existing_servers; do
    server=${server#\'}
    server=${server%\'}
    [ "$server" = "$endpoint" ] || uci add_list "forkop.settings.dns_server=$server"
done

uci set forkop.settings.dns_mtls_enabled='1'
uci set "forkop.settings.dns_mtls_host=$domain"
uci set "forkop.settings.dns_mtls_client_certificate=$client_certificate"
uci set "forkop.settings.dns_mtls_client_key=$client_key"
uci set "forkop.settings.dns_mtls_endpoint=$endpoint"
uci commit forkop

if [ -x /etc/init.d/forkop ]; then
    /etc/init.d/forkop reload
fi

echo "Forkop added mTLS DNS: $endpoint"
