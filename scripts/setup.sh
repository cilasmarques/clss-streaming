#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

mkdir -p \
  media/tv \
  media/movies \
  downloads \
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
chown -R "${PUID}:${PGID}" seerr/config

if [[ ! -f .env ]]; then
  cp .env.example .env
  echo "Created .env from .env.example — edite PLEX_CLAIM, TZ e credenciais antes de subir."
else
  echo ".env já existe — mantido."
fi

echo ""
echo "Estrutura pronta. Próximos passos:"
echo "  1. Edite .env (PLEX_CLAIM, QBITTORRENT_PASSWORD, etc.)"
echo "  2. make up"
echo "  3. make configure   # configura toda a stack após primeira subida"
