#!/usr/bin/env bash
set -euo pipefail

# FluxChat account-service setup for Ubuntu/Debian. The script is intentionally
# idempotent: it preserves a working account configuration and only repairs
# missing pieces when it is run again.

INSTALL_DIR="/opt/fluxchat"
ETC_DIR="/etc/fluxchat"
ACCOUNT_ENV="${ETC_DIR}/account.env"
DISABLED_ACCOUNT_ENV="${ETC_DIR}/account.env.disabled"
SERVICE_DROPIN_DIR="/etc/systemd/system/fluxchat.service.d"
SERVICE_DROPIN="${SERVICE_DROPIN_DIR}/account.conf"
NGINX_AVAILABLE="/etc/nginx/sites-available/fluxchat-account"
NGINX_ENABLED="/etc/nginx/sites-enabled/fluxchat-account"
NGINX_FORCE_CONF="/etc/nginx/conf.d/00-fluxchat-account.conf"
ACME_ROOT="/var/www/fluxchat-acme"
API_PORT="42801"
RELAY_PORT="42800"
SETUP_MARKER="${ETC_DIR}/account-setup-version"
SCRIPT_VERSION="2"

mode="${1:-setup}"

say() { printf '\n[FluxChat Accounts] %s\n' "$*"; }
warn() { printf '\n[FluxChat Accounts] WARNING: %s\n' "$*" >&2; }
fail() { printf '\n[FluxChat Accounts] ERROR: %s\n' "$*" >&2; exit 1; }

require_root() {
    [ "$(id -u)" -eq 0 ] || fail "Run this command as root."
}

require_debian() {
    [ -f /etc/debian_version ] || fail "This setup currently supports Ubuntu and Debian only."
}

install_packages() {
    export DEBIAN_FRONTEND=noninteractive
    say "Installing required packages if needed..."
    apt-get update
    apt-get install -y nginx certbot postgresql postgresql-contrib python3 curl openssl ca-certificates
}

env_value() {
    local name="$1"
    local file="${2:-$ACCOUNT_ENV}"
    [ -f "$file" ] || return 0
    sed -n "s/^${name}=//p" "$file" | tail -n 1
}

is_port_free() {
    local port="$1"
    ! ss -ltnH "sport = :${port}" 2>/dev/null | grep -q . && \
        ! ss -lunH "sport = :${port}" 2>/dev/null | grep -q .
}

choose_https_port() {
    local existing="${1:-}"
    # A previously configured FluxChat nginx listener is expected to occupy its
    # own port. Preserve it on reruns instead of choosing a new URL.
    if [ -n "$existing" ] && [[ "$existing" =~ ^[0-9]+$ ]]; then
        printf '%s' "$existing"
        return
    fi

    local port
    for port in $(seq 8443 8499); do
        if is_port_free "$port"; then
            printf '%s' "$port"
            return
        fi
    done
    fail "No free HTTPS port was found in the 8443-8499 range."
}

detect_public_ip() {
    local ip
    ip="$(curl -4fsS --max-time 8 https://api.ipify.org 2>/dev/null || true)"
    if [ -z "$ip" ]; then
        ip="$(hostname -I | awk '{print $1}')"
    fi
    printf '%s' "$ip"
}

prompt_value() {
    local label="$1"
    local default_value="${2:-}"
    local value
    if [ -n "$default_value" ]; then
        read -r -p "${label} [${default_value}]: " value
        printf '%s' "${value:-$default_value}"
    else
        read -r -p "${label}: " value
        printf '%s' "$value"
    fi
}

prompt_secret() {
    local label="$1"
    local value
    read -r -s -p "${label}: " value
    printf '\n' >&2
    printf '%s' "$value"
}

verify_domain() {
    local domain="$1"
    local expected_ip="$2"
    local resolved
    resolved="$(getent ahostsv4 "$domain" | awk '{print $1}' | sort -u | tr '\n' ' ')"
    [ -n "$resolved" ] || fail "DNS for ${domain} does not resolve yet."
    printf '%s\n' "$resolved" | grep -qw "$expected_ip" || \
        fail "DNS for ${domain} resolves to ${resolved}; it must include ${expected_ip}."
}

write_http_challenge_site() {
    local domain="$1"
    mkdir -p "$ACME_ROOT"
    rm -f "$NGINX_FORCE_CONF"
    cat > "$NGINX_AVAILABLE" <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name ${domain};

    location ^~ /.well-known/acme-challenge/ {
        root ${ACME_ROOT};
        default_type text/plain;
    }

    location / {
        return 404;
    }
}
EOF
    ln -sfn "$NGINX_AVAILABLE" "$NGINX_ENABLED"
    nginx -t
    systemctl reload nginx
}

obtain_certificate() {
    local domain="$1"
    local admin_email="$2"
    if [ ! -f "/etc/letsencrypt/live/${domain}/fullchain.pem" ]; then
        say "Requesting a Let's Encrypt certificate for ${domain}..."
        certbot certonly --webroot -w "$ACME_ROOT" -d "$domain" \
            --non-interactive --agree-tos -m "$admin_email" --keep-until-expiring
    else
        say "Reusing the existing certificate for ${domain}."
    fi
}

cleanup_legacy_nginx_sites() {
    # Older FluxChat badge/account experiments can keep matching server blocks
    # on the same sslip.io domain and make /health work while /api/v1/* returns
    # 404 from a different nginx site.
    rm -f /etc/nginx/sites-enabled/fluxchat-badge-authority
    rm -f /etc/nginx/conf.d/fluxchat-badge-authority.conf
}

write_https_site() {
    local domain="$1"
    local https_port="$2"
    cleanup_legacy_nginx_sites
    rm -f "$NGINX_FORCE_CONF"
    cat > "$NGINX_AVAILABLE" <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name ${domain};

    location ^~ /.well-known/acme-challenge/ {
        root ${ACME_ROOT};
        default_type text/plain;
    }

    location / {
        return 301 https://\$host:${https_port}\$request_uri;
    }
}

server {
    listen ${https_port} ssl http2 default_server;
    listen [::]:${https_port} ssl http2 default_server;
    server_name ${domain};

    ssl_certificate /etc/letsencrypt/live/${domain}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${domain}/privkey.pem;
    client_max_body_size 128m;

    location = /health {
        proxy_pass http://127.0.0.1:${API_PORT}/health;
        proxy_http_version 1.1;
        proxy_set_header Host 127.0.0.1;
        proxy_set_header X-Forwarded-Proto https;
        proxy_set_header X-Real-IP \$remote_addr;
    }

    location ^~ /api/v1/ {
        proxy_pass http://127.0.0.1:${API_PORT};
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Forwarded-Proto https;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    }

    location / {
        proxy_pass http://127.0.0.1:${API_PORT};
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Forwarded-Proto https;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    }
}
EOF
    ln -sfn "$NGINX_AVAILABLE" "$NGINX_ENABLED"
    nginx -t
    systemctl restart nginx
}

write_forced_https_site() {
    local domain="$1"
    local https_port="$2"
    cleanup_legacy_nginx_sites
    rm -f "$NGINX_ENABLED"
    mkdir -p "$(dirname "$NGINX_FORCE_CONF")"
    cat > "$NGINX_FORCE_CONF" <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name ${domain};

    location ^~ /.well-known/acme-challenge/ {
        root ${ACME_ROOT};
        default_type text/plain;
    }

    location / {
        return 301 https://\$host:${https_port}\$request_uri;
    }
}

server {
    listen ${https_port} ssl http2 default_server;
    listen [::]:${https_port} ssl http2 default_server;
    server_name ${domain} _;

    ssl_certificate /etc/letsencrypt/live/${domain}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${domain}/privkey.pem;
    client_max_body_size 128m;

    location = /health {
        proxy_pass http://127.0.0.1:${API_PORT}/health;
        proxy_http_version 1.1;
        proxy_set_header Host 127.0.0.1;
        proxy_set_header X-Forwarded-Proto https;
        proxy_set_header X-Real-IP \$remote_addr;
    }

    location ^~ /api/v1/ {
        proxy_pass http://127.0.0.1:${API_PORT};
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Forwarded-Proto https;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    }

    location / {
        proxy_pass http://127.0.0.1:${API_PORT};
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Forwarded-Proto https;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    }
}
EOF
    nginx -t
    systemctl restart nginx
}

update_public_account_url() {
    local public_url="$1"
    if grep -q '^FLUXCHAT_PUBLIC_ACCOUNT_URL=' "$ACCOUNT_ENV"; then
        sed -i "s#^FLUXCHAT_PUBLIC_ACCOUNT_URL=.*#FLUXCHAT_PUBLIC_ACCOUNT_URL=${public_url}#" "$ACCOUNT_ENV"
    else
        printf 'FLUXCHAT_PUBLIC_ACCOUNT_URL=%s\n' "$public_url" >> "$ACCOUNT_ENV"
    fi
    chmod 600 "$ACCOUNT_ENV"
}

move_account_endpoint_to_free_port() {
    local domain="$1"
    local old_port="$2"
    local new_port
    new_port="$(choose_https_port "")"
    [ "$new_port" != "$old_port" ] || return 1

    warn "Port ${old_port} is answering with the wrong nginx site. Moving the Account API to free port ${new_port}."
    write_https_site "$domain" "$new_port"
    configure_firewall "$new_port"
    update_public_account_url "https://${domain}:${new_port}/"
    systemctl restart fluxchat

    if wait_for_public_ready "https://${domain}:${new_port}/"; then
        say "Public HTTPS Account API recovered on port ${new_port}."
        say "The relay now advertises https://${domain}:${new_port}/ to clients."
        return 0
    fi

    local replacement_code
    replacement_code="$(public_health_code "https://${domain}:${new_port}/")"
    warn "The replacement endpoint on port ${new_port} returned HTTP ${replacement_code}."
    return 1
}

ensure_postgres() {
    local db_password="$1"
    systemctl enable --now postgresql
    if ! runuser -u postgres -- psql -tAc "SELECT 1 FROM pg_roles WHERE rolname = 'fluxchat'" | grep -q 1; then
        runuser -u postgres -- psql -v ON_ERROR_STOP=1 -c "CREATE ROLE fluxchat LOGIN PASSWORD '${db_password}';"
    else
        runuser -u postgres -- psql -v ON_ERROR_STOP=1 -c "ALTER ROLE fluxchat WITH LOGIN PASSWORD '${db_password}';"
    fi
    if ! runuser -u postgres -- psql -tAc "SELECT 1 FROM pg_database WHERE datname = 'fluxchat'" | grep -q 1; then
        runuser -u postgres -- createdb --owner=fluxchat fluxchat
    else
        runuser -u postgres -- psql -v ON_ERROR_STOP=1 -c "ALTER DATABASE fluxchat OWNER TO fluxchat;"
    fi
}

write_account_env() {
    local db_password="$1"
    local data_key="$2"
    local federation_key="$3"
    local public_url="$4"

    mkdir -p "$ETC_DIR"
    umask 077
    cat > "$ACCOUNT_ENV" <<EOF
FLUXCHAT_POSTGRES_CONNECTION=Host=127.0.0.1;Port=5432;Database=fluxchat;Username=fluxchat;Password=${db_password}
FLUXCHAT_DATA_KEY=${data_key}
FLUXCHAT_ACCOUNT_API_PREFIX=http://127.0.0.1:${API_PORT}/
FLUXCHAT_PUBLIC_ACCOUNT_URL=${public_url}
FLUXCHAT_RETENTION_DAYS=730
FLUXCHAT_FEDERATION_SERVER_ID=$(hostname -s)
FLUXCHAT_FEDERATION_KEY=${federation_key}
EOF
    chmod 600 "$ACCOUNT_ENV"
}

write_systemd_dropin() {
    mkdir -p "$SERVICE_DROPIN_DIR"
    cat > "$SERVICE_DROPIN" <<EOF
[Service]
EnvironmentFile=-${ACCOUNT_ENV}
EOF
    systemctl daemon-reload
}

configure_firewall() {
    local https_port="$1"
    if command -v ufw >/dev/null 2>&1; then
        ufw allow 80/tcp || true
        ufw allow "${https_port}/tcp" || true
    fi
}

local_health() {
    curl -fsS --max-time 5 "http://127.0.0.1:${API_PORT}/health" | grep -q '"'
}

public_health() {
    local url="$1"
    curl -fsS --max-time 10 "${url%/}/health" | grep -q '"'
}

local_routes() {
    local code
    code="$(curl --http1.1 -sS --max-time 5 -X POST -H 'Content-Type: application/json' --data-binary '' -o /dev/null -w '%{http_code}' "http://127.0.0.1:${API_PORT}/api/v1/accounts/register" 2>/dev/null || true)"
    [ -n "$code" ] || code="000"
    [ "$code" = "400" ] || [ "$code" = "401" ]
}

local_ready() {
    local_health && local_routes
}

wait_for_local_ready() {
    local attempt
    for attempt in $(seq 1 30); do
        if local_ready; then
            return 0
        fi
        sleep 1
    done
    return 1
}

public_routes() {
    local url="$1"
    local code
    code="$(curl --http1.1 -ksS --max-time 10 -X POST -H 'Content-Type: application/json' --data-binary '' -o /dev/null -w '%{http_code}' "${url%/}/api/v1/accounts/register" 2>/dev/null || true)"
    [ -n "$code" ] || code="000"
    [ "$code" = "400" ] || [ "$code" = "401" ]
}

public_health_code() {
    local url="$1"
    curl -ksS --max-time 10 -o /dev/null -w '%{http_code}' "${url%/}/health" 2>/dev/null || printf '000'
}

public_route_code() {
    local url="$1"
    local code
    code="$(curl --http1.1 -ksS --max-time 10 -X POST -H 'Content-Type: application/json' --data-binary '' -o /dev/null -w '%{http_code}' "${url%/}/api/v1/accounts/register" 2>/dev/null || true)"
    [ -n "$code" ] || code="000"
    printf '%s' "$code"
}

public_ready() {
    local url="$1"
    public_health "$url" && public_routes "$url"
}

wait_for_public_ready() {
    local url="$1"
    local attempt
    for attempt in $(seq 1 8); do
        if public_ready "$url"; then
            return 0
        fi
        sleep 1
    done
    return 1
}

repair_public_https() {
    local domain="$1"
    local https_port="$2"
    local public_url="https://${domain}:${https_port}/"
    local code
    code="$(public_health_code "$public_url")"
    warn "Public HTTPS endpoint failed. Health HTTP ${code}, register route HTTP $(public_route_code "$public_url"). Running automatic diagnostics and repair."

    if ! local_ready; then
        journalctl -u fluxchat -n 80 --no-pager >&2 || true
        fail "Local Account API is not healthy, so nginx cannot proxy it."
    fi

    say "Local Account API is healthy. Rewriting nginx account endpoint."
    write_https_site "$domain" "$https_port" || true
    if public_ready "$public_url"; then
        say "Public HTTPS Account API recovered after rewriting the normal nginx site."
        return
    fi

    code="$(public_health_code "$public_url")"
    warn "Normal nginx site still fails. Health HTTP ${code}, register route HTTP $(public_route_code "$public_url"). Applying forced conf.d endpoint."
    write_forced_https_site "$domain" "$https_port"
    if public_ready "$public_url"; then
        say "Public HTTPS Account API recovered with forced nginx endpoint."
        return
    fi

    code="$(public_health_code "$public_url")"
    if { [ "$code" = "404" ] || [ "$(public_route_code "$public_url")" = "404" ]; } && move_account_endpoint_to_free_port "$domain" "$https_port"; then
        return
    fi

    warn "Nginx listeners on ${https_port}:"
    nginx -T 2>/dev/null | grep -n "listen ${https_port}\|listen \[::\]:${https_port}\|server_name\|proxy_pass" >&2 || true
    fail "The public HTTPS Account API check still fails. Health HTTP ${code}, register route HTTP $(public_route_code "$public_url")."
}

status() {
    local env_file="$ACCOUNT_ENV"
    [ -f "$env_file" ] || env_file="$DISABLED_ACCOUNT_ENV"
    local public_url
    public_url="$(env_value FLUXCHAT_PUBLIC_ACCOUNT_URL "$env_file")"
    local state=0

    printf 'FluxChat account setup status\n\n'
    printf '%-22s %s\n' "Configuration" "$( [ -f "$ACCOUNT_ENV" ] && echo READY || echo MISSING_OR_DISABLED )"
    printf '%-22s %s\n' "PostgreSQL" "$(systemctl is-active postgresql 2>/dev/null || echo inactive)"
    printf '%-22s %s\n' "Relay service" "$(systemctl is-active fluxchat 2>/dev/null || echo inactive)"
    printf '%-22s %s\n' "Nginx" "$(systemctl is-active nginx 2>/dev/null || echo inactive)"
    printf '%-22s %s\n' "Account API local" "$(local_health && echo READY || echo FAILED)"
    printf '%-22s %s\n' "Account routes local" "$(local_routes && echo READY || echo FAILED)"
    printf '%-22s %s\n' "Public URL" "${public_url:-not configured}"
    printf '%-22s %s\n' "HTTPS health" "$( [ -n "$public_url" ] && public_health "$public_url" && echo READY || echo FAILED )"
    printf '%-22s %s\n' "HTTPS routes" "$( [ -n "$public_url" ] && public_routes "$public_url" && echo READY || printf 'FAILED (%s)' "$(public_route_code "$public_url")" )"

    [ -f "$ACCOUNT_ENV" ] || state=1
    systemctl is-active --quiet postgresql || state=1
    systemctl is-active --quiet fluxchat || state=1
    systemctl is-active --quiet nginx || state=1
    local_health || state=1
    local_routes || state=1
    [ -n "$public_url" ] && public_ready "$public_url" || state=1
    return "$state"
}

disable_accounts() {
    require_root
    [ -f "$ACCOUNT_ENV" ] || fail "Account mode is not enabled."
    read -r -p "Disable Account API and its nginx endpoint? Type DISABLE to confirm: " confirmation
    [ "$confirmation" = "DISABLE" ] || { say "Canceled."; return; }
    mv "$ACCOUNT_ENV" "$DISABLED_ACCOUNT_ENV"
    rm -f "$NGINX_ENABLED"
    nginx -t && systemctl reload nginx
    systemctl restart fluxchat
    say "Account API is disabled. PostgreSQL data and ${DISABLED_ACCOUNT_ENV} were kept."
}

setup_accounts() {
    require_root
    require_debian
    install_packages

    if [ -f "$DISABLED_ACCOUNT_ENV" ] && [ ! -f "$ACCOUNT_ENV" ]; then
        say "Restoring the previously disabled account configuration."
        cp "$DISABLED_ACCOUNT_ENV" "$ACCOUNT_ENV"
        chmod 600 "$ACCOUNT_ENV"
    fi

    local public_ip
    public_ip="$(detect_public_ip)"
    [ -n "$public_ip" ] || fail "Could not detect the public VPS IP."
    say "Public VPS IP: ${public_ip}"

    local existing_url existing_domain existing_port default_domain choice domain admin_email
    existing_url="$(env_value FLUXCHAT_PUBLIC_ACCOUNT_URL)"
    existing_domain="$(printf '%s' "$existing_url" | sed -E 's#https?://([^:/]+).*#\1#')"
    existing_port="$(printf '%s' "$existing_url" | sed -nE 's#https?://[^:]+:([0-9]+).*#\1#p')"
    default_domain="${existing_domain:-${public_ip}.sslip.io}"

    echo "Choose the public account address:"
    echo "  1) Automatic sslip.io address (${public_ip}.sslip.io)"
    echo "  2) My own domain"
    read -r -p "Choice [1]: " choice
    case "${choice:-1}" in
        1) domain="${public_ip}.sslip.io" ;;
        2) domain="$(prompt_value 'Domain name' "$existing_domain")" ;;
        *) fail "Choose 1 or 2." ;;
    esac
    [ -n "$domain" ] || fail "A domain name is required."
    verify_domain "$domain" "$public_ip"

    admin_email="$(prompt_value "Email for Let's Encrypt renewal notices" "")"
    [[ "$admin_email" == *@* ]] || fail "Enter a valid email address."

    local https_port
    https_port="$(choose_https_port "$existing_port")"
    say "Using HTTPS port ${https_port}."

    local db_password data_key federation_key postgres_connection
    postgres_connection="$(env_value FLUXCHAT_POSTGRES_CONNECTION)"
    db_password="${postgres_connection##*Password=}"
    [ "$db_password" = "$postgres_connection" ] && db_password=""
    db_password="${db_password%%;*}"
    data_key="$(env_value FLUXCHAT_DATA_KEY)"
    federation_key="$(env_value FLUXCHAT_FEDERATION_KEY)"
    db_password="${db_password:-$(openssl rand -hex 32)}"
    data_key="${data_key:-$(openssl rand -base64 32)}"
    federation_key="${federation_key:-$(openssl rand -base64 48)}"
    ensure_postgres "$db_password"

    write_http_challenge_site "$domain"
    obtain_certificate "$domain" "$admin_email"
    write_https_site "$domain" "$https_port"
    configure_firewall "$https_port"

    write_account_env "$db_password" "$data_key" "$federation_key" \
        "https://${domain}:${https_port}/"
    write_systemd_dropin
    systemctl restart fluxchat
    printf '%s\n' "$SCRIPT_VERSION" > "$SETUP_MARKER"

    if ! wait_for_local_ready; then
        journalctl -u fluxchat -n 80 --no-pager >&2 || true
        fail "The local Account API did not become ready within 30 seconds. The service log above shows the exact reason."
    fi
    public_ready "https://${domain}:${https_port}/" || repair_public_https "$domain" "$https_port"
    local ready_url
    ready_url="$(env_value FLUXCHAT_PUBLIC_ACCOUNT_URL)"
    say "Account service is ready: ${ready_url:-https://${domain}:${https_port}/}"
    say "Client users only enter ${public_ip}:${RELAY_PORT} and their invite code."
}

require_root
case "$mode" in
    status|--status) status ;;
    disable) disable_accounts ;;
    setup|repair|--repair) setup_accounts ;;
    *) fail "Usage: fluxchat-account-setup.sh [setup|status|repair|disable]" ;;
esac
