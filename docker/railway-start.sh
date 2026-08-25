#!/bin/sh
# shellcheck shell=sh
# Railway (and similar PaaS) entrypoint for the official Hermes image.
#
# Railway wraps containers under its own PID 1, so s6-overlay is skipped
# (see docker/entrypoint-dispatch.sh). This script is the single process
# Railway healthchecks: it binds the dashboard to $PORT on 0.0.0.0, seeds
# dashboard auth so a public bind cannot fail-closed, and starts the
# messaging gateway beside it.
#
# Persistent state MUST live on a Railway volume mounted at /opt/data
# (HERMES_HOME). Without that volume, sessions, keys, and the generated
# dashboard password are wiped on every deploy.
#
# Invoked as the image CMD / Railway startCommand. When the image
# entrypoint is PID 1, main-wrapper.sh activates the venv and drops to
# the hermes user before exec'ing us; when Railway's init owns PID 1,
# we activate the venv ourselves.

set -eu

if [ -f /opt/hermes/.venv/bin/activate ]; then
    # shellcheck disable=SC1091
    . /opt/hermes/.venv/bin/activate
fi
export PATH="/opt/hermes/bin:/opt/hermes/.venv/bin:${PATH:-/usr/bin:/bin}"

HERMES_HOME="${HERMES_HOME:-/opt/data}"
export HERMES_HOME
export HOME="$HERMES_HOME"
mkdir -p "$HERMES_HOME/logs" 2>/dev/null || true
cd "$HERMES_HOME"

# Railway's only published port. Do not bind the default 9119 — probes
# and the public domain would 502.
if [ -n "${PORT:-}" ]; then
    dash_port="$PORT"
elif [ -n "${HERMES_DASHBOARD_PORT:-}" ]; then
    dash_port="$HERMES_DASHBOARD_PORT"
else
    dash_port=9119
fi
export HERMES_DASHBOARD_PORT="$dash_port"
export HERMES_DASHBOARD_HOST="${HERMES_DASHBOARD_HOST:-0.0.0.0}"
# Keep the s6 dashboard slot down if /init actually ran: this script owns
# the HTTP listener so we do not double-bind PORT.
export HERMES_DASHBOARD=0

if [ -z "${HERMES_DASHBOARD_PUBLIC_URL:-}" ]; then
    _domain="${RAILWAY_PUBLIC_DOMAIN:-}"
    if [ -z "$_domain" ]; then
        _domain="${RAILWAY_STATIC_URL:-}"
    fi
    if [ -n "$_domain" ]; then
        case "$_domain" in
            http://*|https://*) export HERMES_DASHBOARD_PUBLIC_URL="$_domain" ;;
            *) export HERMES_DASHBOARD_PUBLIC_URL="https://$_domain" ;;
        esac
        echo "[railway] HERMES_DASHBOARD_PUBLIC_URL=${HERMES_DASHBOARD_PUBLIC_URL}"
    fi
fi

upsert_env() {
    _key=$1
    _val=$2
    _file="$HERMES_HOME/.env"
    if [ ! -f "$_file" ]; then
        (umask 077 && touch "$_file") || return 0
    fi
    if grep -q "^${_key}=$" "$_file" 2>/dev/null; then
        sed -i "/^${_key}=$/d" "$_file" 2>/dev/null || true
    fi
    if grep -q "^${_key}=" "$_file" 2>/dev/null; then
        return 0
    fi
    printf '%s=%s\n' "$_key" "$_val" >> "$_file" || true
}

rand_hex() {
    _n=${1:-32}
    if command -v openssl >/dev/null 2>&1; then
        openssl rand -hex "$_n"
        return
    fi
    head -c "$_n" /dev/urandom | od -An -tx1 | tr -d ' \n'
    echo
}

# Public bind requires a DashboardAuthProvider. Prefer operator-supplied
# Railway variables; otherwise mint a password once onto the volume.
_auth_user="${HERMES_DASHBOARD_BASIC_AUTH_USERNAME:-}"
_auth_pass="${HERMES_DASHBOARD_BASIC_AUTH_PASSWORD:-}"
_auth_oauth="${HERMES_DASHBOARD_OAUTH_CLIENT_ID:-}"
_auth_oidc="${HERMES_DASHBOARD_OIDC_CLIENT_ID:-}"

if [ -z "$_auth_oauth" ] && [ -z "$_auth_oidc" ]; then
    if [ -z "$_auth_user" ]; then
        _auth_user="admin"
        export HERMES_DASHBOARD_BASIC_AUTH_USERNAME="$_auth_user"
        upsert_env HERMES_DASHBOARD_BASIC_AUTH_USERNAME "$_auth_user"
    fi
    if [ -z "$_auth_pass" ]; then
        _auth_pass="$(rand_hex 16)"
        export HERMES_DASHBOARD_BASIC_AUTH_PASSWORD="$_auth_pass"
        upsert_env HERMES_DASHBOARD_BASIC_AUTH_PASSWORD "$_auth_pass"
        echo "[railway] Generated dashboard login (persisted under ${HERMES_HOME}/.env)."
        echo "[railway] Username: ${_auth_user}"
        echo "[railway] Password: ${_auth_pass}"
        echo "[railway] Set HERMES_DASHBOARD_BASIC_AUTH_USERNAME / _PASSWORD in Railway variables to choose your own."
    fi
fi

if [ -z "${HERMES_DASHBOARD_BASIC_AUTH_SECRET:-}" ] && [ -z "$_auth_oauth" ] && [ -z "$_auth_oidc" ]; then
    _auth_secret="$(rand_hex 32)"
    export HERMES_DASHBOARD_BASIC_AUTH_SECRET="$_auth_secret"
    upsert_env HERMES_DASHBOARD_BASIC_AUTH_SECRET "$_auth_secret"
fi

# Messaging gateway (Telegram / Discord / …) is a separate process from
# the dashboard. Cron ticks use a file lock, so running both is safe.
_gateway_pid=""
if command -v hermes >/dev/null 2>&1; then
    echo "[railway] starting messaging gateway"
    hermes gateway run >>"$HERMES_HOME/logs/gateway.railway.log" 2>&1 &
    _gateway_pid=$!
fi

_cleanup() {
    if [ -n "${_gateway_pid}" ]; then
        kill "${_gateway_pid}" 2>/dev/null || true
    fi
}
trap _cleanup EXIT INT TERM

echo "[railway] starting dashboard on ${HERMES_DASHBOARD_HOST}:${dash_port}"
exec hermes dashboard \
    --host "$HERMES_DASHBOARD_HOST" \
    --port "$dash_port" \
    --no-open \
    --skip-build
