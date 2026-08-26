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

# uv/venv activate references $OSTYPE; dash + `set -u` aborts there.
OSTYPE="${OSTYPE:-linux-gnu}"
export OSTYPE
if [ -f /opt/hermes/.venv/bin/activate ]; then
    set +u
    # shellcheck disable=SC1091
    . /opt/hermes/.venv/bin/activate
    set -u
fi
# s6-overlay ships helpers under /command, which is not on PATH when
# Railway's PID 1 skips /init. Without this, `command -v s6-setuidgid`
# fails, the dashboard stays root, and `hermes gateway run` exits.
export PATH="/command:/opt/hermes/.venv/bin:/opt/hermes/bin:${PATH:-/usr/bin:/bin}"

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

# Volume .env is loaded later with override=True (load_hermes_dotenv).
# Whatever we export here is discarded unless the same value is written
# to $HERMES_HOME/.env — printing a freshly generated password that was
# skipped by a "key already exists" upsert is how login 401s happen.
envfile_get() {
    _key=$1
    _file="$HERMES_HOME/.env"
    [ -f "$_file" ] || return 0
    grep "^${_key}=" "$_file" 2>/dev/null | tail -n 1 | sed "s/^${_key}=//" | tr -d '\r'
}

write_env() {
    _key=$1
    _val=$2
    _file="$HERMES_HOME/.env"
    if [ ! -f "$_file" ]; then
        (umask 077 && touch "$_file") || return 0
    fi
    if grep -q "^${_key}=" "$_file" 2>/dev/null; then
        grep -v "^${_key}=" "$_file" > "${_file}.tmp" && mv "${_file}.tmp" "$_file"
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

# The hermes exec shim drops root → UID 10000. Earlier Railway boots ran as
# root and left auth.json / hooks / session DBs root-owned; a directory-only
# chown does not fix those files.
if [ "$(id -u)" = 0 ]; then
    chown -R hermes:hermes "$HERMES_HOME" 2>/dev/null || true
fi

# Public bind requires a DashboardAuthProvider. Prefer operator-supplied
# Railway variables; otherwise reuse (or mint once) credentials on the volume.
# Always write the chosen values back to .env so dotenv override cannot
# swap in a stale password that was never printed.
_auth_user="${HERMES_DASHBOARD_BASIC_AUTH_USERNAME:-}"
_auth_pass="${HERMES_DASHBOARD_BASIC_AUTH_PASSWORD:-}"
_auth_secret="${HERMES_DASHBOARD_BASIC_AUTH_SECRET:-}"
_auth_oauth="${HERMES_DASHBOARD_OAUTH_CLIENT_ID:-}"
_auth_oidc="${HERMES_DASHBOARD_OIDC_CLIENT_ID:-}"
_auth_pass_source="env"

if [ -z "$_auth_oauth" ] && [ -z "$_auth_oidc" ]; then
    if [ -z "$_auth_user" ]; then
        _auth_user="$(envfile_get HERMES_DASHBOARD_BASIC_AUTH_USERNAME)"
    fi
    if [ -z "$_auth_user" ]; then
        _auth_user="admin"
    fi
    export HERMES_DASHBOARD_BASIC_AUTH_USERNAME="$_auth_user"
    write_env HERMES_DASHBOARD_BASIC_AUTH_USERNAME "$_auth_user"

    if [ -z "$_auth_pass" ]; then
        _auth_pass="$(envfile_get HERMES_DASHBOARD_BASIC_AUTH_PASSWORD)"
        if [ -n "$_auth_pass" ]; then
            _auth_pass_source="envfile"
        fi
    fi
    if [ -z "$_auth_pass" ]; then
        _auth_pass="$(rand_hex 16)"
        _auth_pass_source="generated"
    fi
    export HERMES_DASHBOARD_BASIC_AUTH_PASSWORD="$_auth_pass"
    write_env HERMES_DASHBOARD_BASIC_AUTH_PASSWORD "$_auth_pass"

    echo "[railway] Dashboard login username: ${_auth_user}"
    if [ "$_auth_pass_source" = "generated" ]; then
        echo "[railway] Generated dashboard password (persisted under ${HERMES_HOME}/.env)."
        echo "[railway] Password: ${_auth_pass}"
        echo "[railway] Set HERMES_DASHBOARD_BASIC_AUTH_USERNAME / _PASSWORD in Railway variables to choose your own."
    elif [ "$_auth_pass_source" = "envfile" ]; then
        echo "[railway] Reusing dashboard password from ${HERMES_HOME}/.env (not regenerated)."
    else
        echo "[railway] Using dashboard password from the environment; synced to ${HERMES_HOME}/.env."
    fi
fi

if [ -z "$_auth_oauth" ] && [ -z "$_auth_oidc" ]; then
    if [ -z "$_auth_secret" ]; then
        _auth_secret="$(envfile_get HERMES_DASHBOARD_BASIC_AUTH_SECRET)"
    fi
    if [ -z "$_auth_secret" ]; then
        _auth_secret="$(rand_hex 32)"
    fi
    export HERMES_DASHBOARD_BASIC_AUTH_SECRET="$_auth_secret"
    write_env HERMES_DASHBOARD_BASIC_AUTH_SECRET "$_auth_secret"
fi

# Inference keys from Railway Variables must match $HERMES_HOME/.env.
# load_hermes_dotenv() loads that file with override=True.
if [ -n "${OPENROUTER_PROVISIONING_KEY:-}" ]; then
    write_env OPENROUTER_PROVISIONING_KEY "$OPENROUTER_PROVISIONING_KEY"
fi
if [ -n "${OPENROUTER_API_KEY:-}" ]; then
    write_env OPENROUTER_API_KEY "$OPENROUTER_API_KEY"
fi
# Management keys pass GET /api/v1/key but chat returns HTTP 401 User not found.
/opt/hermes/.venv/bin/python -m hermes_cli.openrouter_key || \
    echo "[railway] warning: could not normalize OpenRouter inference key" >&2
if [ -n "${OPENAI_API_KEY:-}" ]; then
    write_env OPENAI_API_KEY "$OPENAI_API_KEY"
fi
if [ -n "${ANTHROPIC_API_KEY:-}" ]; then
    write_env ANTHROPIC_API_KEY "$ANTHROPIC_API_KEY"
fi
# Remote computer for bots. Local terminal is the laptop default; on Railway
# the replica is not a useful sandbox. Daytona is the hosted computer.
if [ -z "${DAYTONA_API_KEY:-}" ]; then
    _daytona_key="$(envfile_get DAYTONA_API_KEY)"
    if [ -n "$_daytona_key" ]; then
        DAYTONA_API_KEY="$_daytona_key"
        export DAYTONA_API_KEY
    fi
fi
if [ -z "${DAYTONA_API_URL:-}" ]; then
    _daytona_url="$(envfile_get DAYTONA_API_URL)"
    if [ -n "$_daytona_url" ]; then
        DAYTONA_API_URL="$_daytona_url"
        export DAYTONA_API_URL
    fi
fi
if [ -n "${DAYTONA_API_KEY:-}" ]; then
    write_env DAYTONA_API_KEY "$DAYTONA_API_KEY"
fi
if [ -n "${DAYTONA_API_URL:-}" ]; then
    write_env DAYTONA_API_URL "$DAYTONA_API_URL"
fi

if [ -n "${DAYTONA_API_KEY:-}" ]; then
    /opt/hermes/.venv/bin/python -m hermes_cli.railway_online || \
        echo "[railway] warning: could not merge terminal.backend=daytona into config.yaml" >&2
fi

if [ "$(id -u)" = 0 ]; then
    if [ -f "$HERMES_HOME/.env" ]; then
        chown hermes:hermes "$HERMES_HOME/.env" 2>/dev/null || true
        chmod 600 "$HERMES_HOME/.env" 2>/dev/null || true
    fi
    if [ -f "$HERMES_HOME/config.yaml" ]; then
        chown hermes:hermes "$HERMES_HOME/config.yaml" 2>/dev/null || true
    fi
fi

run_hermes() {
    if [ "$(id -u)" = 0 ] && command -v s6-setuidgid >/dev/null 2>&1; then
        s6-setuidgid hermes /opt/hermes/.venv/bin/hermes "$@"
    else
        /opt/hermes/.venv/bin/hermes "$@"
    fi
}

# Messaging gateway (Telegram / Discord / …) is a separate process from
# the dashboard. Cron ticks use a file lock, so running both is safe.
_gateway_pid=""
echo "[railway] starting messaging gateway"
run_hermes gateway run >>"$HERMES_HOME/logs/gateway.railway.log" 2>&1 &
_gateway_pid=$!

_cleanup() {
    if [ -n "${_gateway_pid}" ]; then
        kill "${_gateway_pid}" 2>/dev/null || true
    fi
}
trap _cleanup EXIT INT TERM

echo "[railway] starting dashboard on ${HERMES_DASHBOARD_HOST}:${dash_port}"
if [ "$(id -u)" = 0 ] && command -v s6-setuidgid >/dev/null 2>&1; then
    exec s6-setuidgid hermes /opt/hermes/.venv/bin/hermes dashboard \
        --host "$HERMES_DASHBOARD_HOST" \
        --port "$dash_port" \
        --no-open \
        --skip-build
fi
exec /opt/hermes/.venv/bin/hermes dashboard \
    --host "$HERMES_DASHBOARD_HOST" \
    --port "$dash_port" \
    --no-open \
    --skip-build
