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

DRY_RUN="${DRY_RUN:-${E2E_DRY_RUN:-true}}"
MOVIE_TMDB_ID="${MOVIE_TMDB_ID:-${E2E_MOVIE_TMDB_ID:-550}}"
MOVIE_TITLE="${MOVIE_TITLE:-${E2E_MOVIE_TITLE:-Fight Club}}"

RADARR_PORT="${RADARR_PORT:-7878}"
PROWLARR_PORT="${PROWLARR_PORT:-9696}"
WEBUI_PORT="${WEBUI_PORT:-8082}"
BAZARR_PORT="${BAZARR_PORT:-6767}"
SEERR_PORT="${SEERR_PORT:-5055}"
QBITTORRENT_USER="${QBITTORRENT_USER:-${COMMON_USER:-admin}}"
QBITTORRENT_PASSWORD="${QBITTORRENT_PASSWORD:-${COMMON_PASSWORD:-}}"

if [[ "$DRY_RUN" != "true" ]]; then
  if [[ "${E2E_AUTHORIZED_CONTENT:-false}" != "true" ]]; then
    log_err "DRY_RUN=false exige E2E_AUTHORIZED_CONTENT=true e um MOVIE_TMDB_ID/MOVIE_TITLE legal, próprio, livre ou autorizado."
    exit 1
  fi
  log_warn "Teste real autorizado solicitado; este script ainda valida integrações e não inicia download automaticamente."
fi

api_key_from_config() {
  local file="$1"
  grep -oE '<ApiKey>[^<]+' "$file" 2>/dev/null | sed 's/<ApiKey>//' | head -1
}

radarr_api() {
  curl -fsS "http://127.0.0.1:${RADARR_PORT}/api/v3$1" -H "X-Api-Key: $radarr_key"
}

prowlarr_api() {
  curl -fsS "http://127.0.0.1:${PROWLARR_PORT}/api/v1$1" -H "X-Api-Key: $prowlarr_key"
}

radarr_key="$(api_key_from_config radarr/config/config.xml)"
prowlarr_key="$(api_key_from_config prowlarr/config/config.xml)"
[[ -n "$radarr_key" ]] || { log_err "API key do Radarr ausente"; exit 1; }
[[ -n "$prowlarr_key" ]] || { log_err "API key do Prowlarr ausente"; exit 1; }

log_info "Validando serviços base"
curl -fsS "http://127.0.0.1:${SEERR_PORT}/api/v1/status" >/dev/null || { log_err "Seerr indisponível"; exit 1; }
radarr_api /system/status >/dev/null || { log_err "Radarr API indisponível"; exit 1; }
prowlarr_api /system/status >/dev/null || { log_err "Prowlarr API indisponível"; exit 1; }
curl -fsS "http://127.0.0.1:${BAZARR_PORT}/api/system/ping" >/dev/null || { log_err "Bazarr indisponível"; exit 1; }
log_ok "Serviços principais respondem"

log_info "Validando paths compartilhados dentro dos containers"
docker compose exec -T qbittorrent test -d /data/downloads
docker compose exec -T radarr test -d /data/downloads
docker compose exec -T radarr test -d /data/movies
docker compose exec -T jellyfin test -d /data/movies
docker compose exec -T plex test -d /data/movies
log_ok "Containers enxergam downloads e biblioteca de filmes"

log_info "Validando Radarr"
root_summary="$(radarr_api /rootfolder | jq -r '{total:length, movies:([.[] | select(.path == "/data/movies")] | length)}')"
root_total="$(jq -r '.total' <<<"$root_summary")"
root_movies="$(jq -r '.movies' <<<"$root_summary")"
[[ "$root_total" -eq 1 && "$root_movies" -eq 1 ]] || {
  log_err "Radarr deve possuir exatamente um root folder, e ele deve ser /data/movies"
  exit 1
}
client_json="$(radarr_api /downloadclient)"
client_id="$(jq -r '.[] | select(.implementation == "QBittorrent" or .name == "qBittorrent") | .id' <<<"$client_json" | head -1)"
[[ -n "$client_id" ]] || { log_err "Radarr não possui download client qBittorrent"; exit 1; }
jq -e '.[] | select(.id == '"$client_id"') | .fields[] | select(.name=="host" and .value=="qbittorrent")' <<<"$client_json" >/dev/null || {
  log_err "Download client do Radarr não aponta para host interno qbittorrent"
  exit 1
}
jq -e '.[] | select(.id == '"$client_id"') | .fields[] | select(.name=="movieCategory" and .value=="movies-radarr")' <<<"$client_json" >/dev/null || {
  log_err "Download client do Radarr não usa categoria movies-radarr"
  exit 1
}
client_payload="$(jq '.[] | select(.id == '"$client_id"')' <<<"$client_json")"
curl -fsS -X POST "http://127.0.0.1:${RADARR_PORT}/api/v3/downloadclient/test" \
  -H "X-Api-Key: $radarr_key" -H "Content-Type: application/json" -d "$client_payload" >/dev/null || {
  log_err "Radarr não conseguiu testar conexão com qBittorrent"
  exit 1
}
log_ok "Radarr possui /data/movies e qBittorrent funcional"

log_info "Validando qBittorrent"
cookie_jar="$(mktemp)"
trap 'rm -f "$cookie_jar"' EXIT
[[ -n "$QBITTORRENT_PASSWORD" ]] || { log_err "QBITTORRENT_PASSWORD ausente"; exit 1; }
curl -fsS -X POST "http://127.0.0.1:${WEBUI_PORT}/api/v2/auth/login" \
  -c "$cookie_jar" -b "$cookie_jar" \
  --data "username=${QBITTORRENT_USER}&password=${QBITTORRENT_PASSWORD}" >/dev/null || {
  log_err "Falha no login do qBittorrent com credenciais do .env"
  exit 1
}
curl -fsS "http://127.0.0.1:${WEBUI_PORT}/api/v2/torrents/categories" -b "$cookie_jar" \
  | jq -e 'has("movies-radarr") or has("tv-sonarr")' >/dev/null || log_warn "Categorias qBittorrent ainda não aparecem via API; Radarr pode criá-las no primeiro uso."
log_ok "qBittorrent aceita credenciais do .env"

log_info "Validando Prowlarr e indexers"
apps="$(prowlarr_api /applications)"
jq -e '.[] | select(.implementation == "Radarr" and (.fields[]? | select(.name=="baseUrl" and .value=="http://radarr:7878")))' <<<"$apps" >/dev/null || {
  log_err "Prowlarr não possui Application Radarr apontando para http://radarr:7878"
  exit 1
}
indexers="$(prowlarr_api /indexer)"
enabled_indexer_count="$(jq '[.[] | select(.enable == true)] | length' <<<"$indexers")"
if [[ "$enabled_indexer_count" -eq 0 ]]; then
  log_warn "Nenhum indexer ativo no Prowlarr; dependência externa/manual para busca de releases."
else
  log_ok "Prowlarr possui $enabled_indexer_count indexer(s) ativo(s)"
fi
radarr_indexer_count="$(radarr_api /indexer | jq 'length')"
if [[ "$radarr_indexer_count" -eq 0 ]]; then
  log_warn "Radarr ainda não recebeu indexers sincronizados; rode make configure novamente após configurar indexers no Prowlarr."
else
  log_ok "Radarr possui $radarr_indexer_count indexer(s) sincronizado(s)"
fi

log_info "Validando Seerr -> Radarr"
seerr_settings="seerr/config/settings.json"
if [[ -f "$seerr_settings" ]] && jq -e '.radarr[]? | select(.hostname=="radarr" and .activeDirectory=="/data/movies")' "$seerr_settings" >/dev/null; then
  log_ok "Seerr possui integração Radarr com /data/movies"
else
  log_err "Seerr não possui integração Radarr comprovada em settings.json"
  exit 1
fi

log_info "Validando Bazarr -> Radarr e perfil português"
if [[ -f bazarr/config/config/config.yaml ]]; then
  python3 - <<'PY'
import sqlite3, sys, yaml
cfg = yaml.safe_load(open("bazarr/config/config/config.yaml")) or {}
if cfg.get("radarr", {}).get("ip") != "radarr":
    raise SystemExit("Bazarr não aponta para Radarr interno")
if not cfg.get("general", {}).get("use_radarr"):
    raise SystemExit("Bazarr não está com Radarr habilitado")
conn = sqlite3.connect("bazarr/config/db/bazarr.db")
rows = conn.execute("select name, items from table_languages_profiles").fetchall()
conn.close()
if not any(("Portugu" in name and ("pob" in (items or "") or "por" in (items or ""))) for name, items in rows):
    raise SystemExit("Perfil de legenda português não encontrado no Bazarr")
PY
  log_ok "Bazarr aponta para Radarr e possui perfil português"
else
  log_err "Configuração do Bazarr ainda não existe"
  exit 1
fi

if [[ "$enabled_indexer_count" -gt 0 ]]; then
  log_info "Validando capacidade de busca sem iniciar download para ${MOVIE_TITLE} (${MOVIE_TMDB_ID})"
  if prowlarr_api "/search?query=$(python3 -c 'import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))' "$MOVIE_TITLE")&type=movie" >/tmp/clss-prowlarr-search.json; then
    result_count="$(jq 'length' /tmp/clss-prowlarr-search.json)"
    if [[ "$result_count" -eq 0 ]]; then
      log_warn "Busca executou, mas não retornou releases para este título; não é falha de infraestrutura em dry-run."
    else
      log_ok "Busca retornou $result_count resultado(s) via Prowlarr"
    fi
  else
    log_warn "Busca via Prowlarr falhou; verifique indexer, login, região ou disponibilidade externa."
  fi
  rm -f /tmp/clss-prowlarr-search.json
fi

log_ok "E2E dry-run concluído sem iniciar download real"
