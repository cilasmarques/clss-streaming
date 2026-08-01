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

log_info "Validando dependências locais"
require_cmd docker
docker compose version >/dev/null 2>&1 || {
  log_err "Dependência ausente: docker compose"
  exit 1
}
require_cmd curl
require_cmd jq
require_cmd python3
python3 - <<'PY'
import importlib.util
raise SystemExit(0 if importlib.util.find_spec("yaml") else "Dependência Python ausente: PyYAML")
PY
log_ok "Dependências locais encontradas"

log_info "Validando sintaxe shell"
while IFS= read -r script; do
  bash -n "$script"
done < <(find scripts -maxdepth 1 -type f -name '*.sh' | sort)
log_ok "Scripts shell válidos"

log_info "Validando arquivos referenciados"
for file in Makefile docker-compose.yml scripts/setup.sh scripts/configure.sh scripts/arr-stack.json .env.example README.md; do
  [[ -f "$file" ]] || {
    log_err "Arquivo obrigatório ausente: $file"
    exit 1
  }
done
for script in scripts/validate.sh scripts/smoke-test.sh scripts/e2e-test.sh; do
  [[ -x "$script" ]] || {
    log_err "Script ausente ou sem permissão de execução: $script"
    exit 1
  }
done
if grep -Eq 'configure-bazarr\.sh|search-missing\.sh' README.md; then
  log_err "README referencia script inexistente"
  exit 1
fi
log_ok "Referências básicas consistentes"

log_info "Validando .env"
if [[ ! -f .env ]]; then
  log_err ".env ausente. Execute make setup e preencha os placeholders necessários."
  exit 1
fi
# shellcheck disable=SC1091
set -a && source .env && set +a
required_vars=(
  PUID PGID TZ COMMON_USER COMMON_PASSWORD QBITTORRENT_USER QBITTORRENT_PASSWORD
  SEERR_ADMIN_EMAIL SEERR_ADMIN_PASSWORD
  JELLYFIN_ADMIN_USER JELLYFIN_ADMIN_PASSWORD
)
for var in "${required_vars[@]}"; do
  if [[ -z "${!var:-}" ]]; then
    log_err "Variável obrigatória vazia ou ausente no .env: $var"
    exit 1
  fi
done
defaulted_vars=(
  WEBUI_PORT QBITTORRENT_PEER_PORT SONARR_PORT RADARR_PORT PROWLARR_PORT
  BAZARR_PORT JELLYFIN_PORT SEERR_PORT
)
for var in "${defaulted_vars[@]}"; do
  if [[ -z "${!var:-}" ]]; then
    log_warn "$var ausente no .env; será usado o default do Compose/script."
  fi
done
if [[ "${PLEX_CLAIM:-}" == "claim-xxxxxxxxxxxxxxxxxxxx" || -z "${PLEX_CLAIM:-}" ]]; then
  log_warn "PLEX_CLAIM ausente ou placeholder; Plex pode exigir claim manual externo."
fi
log_ok ".env possui variáveis mínimas"

log_info "Validando Docker Compose resolvido"
docker compose config --quiet
log_ok "docker compose config passou"

log_info "Validando diretórios e volumes"
for dir in media/downloads media/movies media/tv plex/config jellyfin/config radarr/config sonarr/config qbittorrent/config prowlarr/config bazarr/config seerr/config; do
  [[ -d "$dir" ]] || {
    log_err "Diretório esperado ausente: $dir"
    exit 1
  }
done
python3 - <<'PY'
from pathlib import Path
compose = Path("docker-compose.yml").read_text()
required = {
    "./media:/data": "mount unico de mídia",
}
missing = [label for text, label in required.items() if text not in compose]
if missing:
    raise SystemExit("Volumes inconsistentes: " + ", ".join(missing))
PY
log_ok "Volumes básicos consistentes"

log_info "Verificando segredos óbvios em arquivos versionados"
if git grep -nE '(ClssStream[0-9!]+|PLEX_CLAIM=claim-[A-Za-z0-9_-]{8,}|apiKey[" ]*[:=][" ]*[A-Za-z0-9]{20,})' -- \
  ':!.env.example' ':!README.md' >/tmp/clss-secret-scan.txt 2>/dev/null; then
  cat /tmp/clss-secret-scan.txt >&2
  log_err "Possível segredo real encontrado em arquivo versionado"
  exit 1
fi
rm -f /tmp/clss-secret-scan.txt
log_ok "Nenhum segredo óbvio encontrado em arquivos versionados"

log_ok "Validação concluída"
