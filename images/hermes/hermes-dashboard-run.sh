#!/bin/bash
# Run Hermes dashboard inside the OpenShell sandbox netns.
#
# System unit hermes-dashboard.service uses this in BOTH supervisor modes so
# the gateway entrypoint can stay a single foreground MainPID (no bash job
# control). Traffic still goes through the sandbox netns L7 proxy; the
# dashboard process is not under combined-mode Landlock (FS policy only on
# the OpenShell process leaf).
set -euo pipefail

NETNS_FILE="${OPENSHELL_NETNS_FILE:-/run/openshell/netns}"
PROVIDER_ENV="${OPENSHELL_PROVIDER_ENV:-/run/openshell/provider.env}"
PROXY_HOST="${NEMOCLAW_PROXY_HOST:-10.200.0.1}"
PROXY_PORT="${NEMOCLAW_PROXY_PORT:-3128}"
SANDBOX_UID="${OPENSHELL_SANDBOX_UID:-10001}"
SANDBOX_GID="${OPENSHELL_SANDBOX_GID:-10001}"
LOG_DIR="${HERMES_HOME:-/sandbox/.hermes}/runtime"

log() { echo "hermes-dashboard: $*" >&2; }

if [ "${HERMES_DASHBOARD_IN_NETNS:-}" = "1" ]; then
  if [ -f "$PROVIDER_ENV" ]; then
    set -a
    # shellcheck disable=SC1090
    . "$PROVIDER_ENV"
    set +a
  fi
  if [ -r /etc/sandbox/env ]; then
    set -a
    # shellcheck disable=SC1091
    . /etc/sandbox/env
    set +a
  fi

  _PROXY_URL="http://${PROXY_HOST}:${PROXY_PORT}"
  export HTTP_PROXY="$_PROXY_URL" HTTPS_PROXY="$_PROXY_URL" ALL_PROXY="$_PROXY_URL"
  export http_proxy="$_PROXY_URL" https_proxy="$_PROXY_URL" all_proxy="$_PROXY_URL"
  export grpc_proxy="$_PROXY_URL"
  export NO_PROXY="localhost,127.0.0.1,::1,${PROXY_HOST}"
  export no_proxy="$NO_PROXY"
  export NODE_USE_ENV_PROXY="${NODE_USE_ENV_PROXY:-1}"
  export PYTHONPATH="/usr/local/lib/hermes/pythonpath${PYTHONPATH:+:${PYTHONPATH}}"
  export HOME="${HOME:-/sandbox}"
  export HERMES_HOME="${HERMES_HOME:-/sandbox/.hermes}"
  export HERMES_TUI_DIR="${HERMES_TUI_DIR:-/opt/hermes/ui-tui}"
  export PATH="/opt/hermes/.venv/bin:/usr/local/bin:/usr/bin:/bin:${PATH:-}"
  export USER=sandbox
  export LOGNAME=sandbox

  for cand in \
    /etc/openshell-tls/ca-bundle.pem \
    /etc/openshell-tls/openshell-ca.pem \
    /run/openshell/ca-bundle.pem \
    /run/openshell/openshell-ca.pem; do
    if [ -s "$cand" ]; then
      export SSL_CERT_FILE="$cand"
      export REQUESTS_CA_BUNDLE="$cand"
      export CURL_CA_BUNDLE="$cand"
      export GIT_SSL_CAINFO="$cand"
      export NODE_EXTRA_CA_CERTS="$cand"
      export DENO_CERT="$cand"
      break
    fi
  done

  mkdir -p "$LOG_DIR"
  cd "$HOME"

  if [ "$(id -u)" -eq 0 ]; then
    if command -v setpriv >/dev/null 2>&1; then
      exec setpriv --reuid="$SANDBOX_UID" --regid="$SANDBOX_GID" --init-groups -- \
        /opt/hermes/.venv/bin/hermes dashboard --host 127.0.0.1 --port 9119 --no-open
    fi
    exec runuser -u sandbox -- \
      /opt/hermes/.venv/bin/hermes dashboard --host 127.0.0.1 --port 9119 --no-open
  fi
  exec /opt/hermes/.venv/bin/hermes dashboard --host 127.0.0.1 --port 9119 --no-open
fi

resolve_netns() {
  local path name
  if [ -f "$NETNS_FILE" ]; then
    path="$(tr -d '[:space:]' <"$NETNS_FILE")"
    if [ -n "$path" ] && [ -e "$path" ]; then
      printf '%s\n' "$path"
      return 0
    fi
  fi
  name="$(ip netns list 2>/dev/null | awk '/^sandbox-/ {print $1; exit}')"
  if [ -n "$name" ]; then
    for base in /run/netns /var/run/netns; do
      if [ -e "$base/$name" ]; then
        printf '%s\n' "$base/$name"
        return 0
      fi
    done
  fi
  return 1
}

NETNS_PATH=""
for _ in $(seq 1 120); do
  if NETNS_PATH="$(resolve_netns)"; then
    break
  fi
  NETNS_PATH=""
  sleep 1
done
if [ -z "$NETNS_PATH" ]; then
  log "timed out waiting for sandbox netns ($NETNS_FILE or ip netns sandbox-*)"
  exit 1
fi

log "entering netns $NETNS_PATH"
exec nsenter --net="$NETNS_PATH" env HERMES_DASHBOARD_IN_NETNS=1 "$0"
