#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

log_info() { echo "-> $*"; }
log_ok() { echo "OK: $*"; }
log_warn() { echo "WARN: $*"; }
log_err() { echo "ERROR: $*" >&2; }

if [[ ! -f .env ]]; then
  log_err ".env ausente. Execute make setup antes."
  exit 1
fi
# shellcheck disable=SC1091
set -a && source .env && set +a

RADARR_PORT="${RADARR_PORT:-7878}"
SONARR_PORT="${SONARR_PORT:-8989}"
PROWLARR_PORT="${PROWLARR_PORT:-9696}"
WEBUI_PORT="${WEBUI_PORT:-8082}"
BAZARR_PORT="${BAZARR_PORT:-6767}"
JELLYFIN_PORT="${JELLYFIN_PORT:-8096}"
SEERR_PORT="${SEERR_PORT:-5055}"

api_key_from_config() {
  local file="$1"
  grep -oE '<ApiKey>[^<]+' "$file" 2>/dev/null | sed 's/<ApiKey>//' | head -1
}

check_container() {
  local service="$1"
  local state
  state="$(docker compose ps --status running --services | grep -Fx "$service" || true)"
  if [[ "$state" != "$service" ]]; then
    log_err "Container não está em execução: $service"
    return 1
  fi
  log_ok "Container em execução: $service"
}

check_http() {
  local name="$1" url="$2" display_url="${3:-$2}"
  if curl -fsS --max-time 10 "$url" >/dev/null; then
    log_ok "$name responde em $display_url"
  else
    log_err "$name não respondeu em $display_url"
    return 1
  fi
}

log_info "Verificando containers"
for service in seerr radarr prowlarr qbittorrent bazarr jellyfin plex; do
  check_container "$service"
done

log_info "Verificando endpoints HTTP/API"
radarr_key="$(api_key_from_config radarr/config/config.xml)"
prowlarr_key="$(api_key_from_config prowlarr/config/config.xml)"
sonarr_key="$(api_key_from_config sonarr/config/config.xml || true)"

[[ -n "$radarr_key" ]] || { log_err "API key do Radarr ausente em radarr/config/config.xml"; exit 1; }
[[ -n "$prowlarr_key" ]] || { log_err "API key do Prowlarr ausente em prowlarr/config/config.xml"; exit 1; }
[[ -n "$sonarr_key" ]] || log_warn "API key do Sonarr ausente; o fluxo principal de filmes ainda pode ser validado"

check_http "Seerr" "http://127.0.0.1:${SEERR_PORT}/api/v1/status"
check_http "Radarr API" "http://127.0.0.1:${RADARR_PORT}/api/v3/system/status?apikey=${radarr_key}" "http://127.0.0.1:${RADARR_PORT}/api/v3/system/status?apikey=<redacted>"
check_http "Prowlarr API" "http://127.0.0.1:${PROWLARR_PORT}/api/v1/system/status?apikey=${prowlarr_key}" "http://127.0.0.1:${PROWLARR_PORT}/api/v1/system/status?apikey=<redacted>"
check_http "qBittorrent Web UI" "http://127.0.0.1:${WEBUI_PORT}"
check_http "Bazarr" "http://127.0.0.1:${BAZARR_PORT}/api/system/ping"
check_http "Jellyfin" "http://127.0.0.1:${JELLYFIN_PORT}/System/Info/Public"
check_http "Plex" "http://127.0.0.1:32400/identity"

log_ok "Smoke test concluído"
