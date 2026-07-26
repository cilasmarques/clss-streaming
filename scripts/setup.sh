#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

log_info() { echo "-> $*"; }
log_ok() { echo "OK: $*"; }
log_warn() { echo "WARN: $*"; }
log_err() { echo "ERROR: $*" >&2; }

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    log_err "Dependência ausente: $1"
    exit 1
  fi
}

require_cmd docker
docker compose version >/dev/null 2>&1 || {
  log_err "Dependência ausente: docker compose"
  exit 1
}
require_cmd curl
require_cmd jq
require_cmd python3

if ! docker network inspect traefik-public >/dev/null 2>&1; then
  log_warn "Rede externa Docker 'traefik-public' não existe. Crie-a ou ajuste docker-compose.yml antes de make up."
fi

mkdir -p \
  media/tv \
  media/movies \
  media/downloads \
  plex/config \
  sonarr/config \
  radarr/config \
  qbittorrent/config \
  prowlarr/config \
  bazarr/config \
  jellyfin/config \
  seerr/config

if [[ -f .env ]]; then
  # shellcheck disable=SC1091
  set -a
  source .env
  set +a
fi
PUID="${PUID:-$(id -u)}"
PGID="${PGID:-$(id -g)}"

for dir in media plex/config sonarr/config radarr/config qbittorrent/config prowlarr/config bazarr/config jellyfin/config seerr/config; do
  chown -R "${PUID}:${PGID}" "$dir"
done

if [[ ! -f .env ]]; then
  cp .env.example .env
  log_ok "Criado .env a partir de .env.example. Edite credenciais, PLEX_CLAIM e portas antes de make up."
else
  log_ok ".env já existe; mantido sem alterações."
fi

echo ""
echo "Estrutura pronta. Próximos passos:"
echo "  1. Edite .env se ainda houver placeholders"
echo "  2. make up"
echo "  3. make configure"
