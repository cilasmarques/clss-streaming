#!/usr/bin/env bash
# Idempotent post-deploy configuration for the full streaming stack.
# Run after: docker compose up -d (and services have created their config.xml)
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

CONFIG_FILE="$ROOT_DIR/scripts/arr-stack.json"

# shellcheck disable=SC2154
api_key_from_config() {
  local config_file="$1"
  grep -oP '(?<=<ApiKey>)[^<]+' "$config_file" 2>/dev/null || true
}

wait_for_http() {
  local url="$1"
  local label="$2"
  local max_attempts="${3:-30}"

  for ((i = 1; i <= max_attempts; i++)); do
    if curl -sf "$url" >/dev/null 2>&1; then
      log_ok "$label disponível"
      return 0
    fi
    sleep 2
  done

  log_err "$label não respondeu em $((max_attempts * 2))s ($url)"
  return 1
}

log_info() { echo "→ $*"; }
log_ok()   { echo "✓ $*"; }
log_warn() { echo "! $*"; }
log_err()  { echo "✗ $*" >&2; }

if [[ ! -f .env ]]; then
  log_err "Arquivo .env não encontrado. Execute ./setup.sh primeiro."
  exit 1
fi

# shellcheck disable=SC1091
set -a && source .env && set +a

if [[ ! -f "$CONFIG_FILE" ]]; then
  log_err "Configuração não encontrada: $CONFIG_FILE"
  exit 1
fi

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    log_err "Dependência ausente: $1"
    exit 1
  fi
}

require_cmd curl
require_cmd jq
require_cmd docker
require_cmd python3

QBITTORRENT_COOKIE_JAR="$(mktemp)"

# -----------------------------------------------------------------------------
# Generic helpers
# -----------------------------------------------------------------------------

read_config() {
  python3 - "$CONFIG_FILE" "$1" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
key = sys.argv[2]
print(json.dumps(data[key]))
PY
}

get_api_key() {
  local rel_path="$1"
  local config_path="$ROOT_DIR/$rel_path"
  if [[ ! -f "$config_path" ]]; then
    log_err "API key não encontrada ($config_path). Suba os containers e aguarde a inicialização."
    exit 1
  fi
  api_key_from_config "$config_path"
}

qbittorrent_base_url() {
  printf 'http://127.0.0.1:%s' "${WEBUI_PORT:-8082}"
}

qbittorrent_login() {
  local password="$1"
  : > "$QBITTORRENT_COOKIE_JAR"
  curl -fsS -X POST "$(qbittorrent_base_url)/api/v2/auth/login" \
    -b "$QBITTORRENT_COOKIE_JAR" \
    -c "$QBITTORRENT_COOKIE_JAR" \
    --data "username=${QBITTORRENT_USER:-admin}&password=${password}" >/dev/null
}

qbittorrent_temp_password() {
  docker logs qbittorrent 2>/dev/null     | sed -n 's/.*temporary password is provided for this session: //p'     | tail -n 1
}

ensure_qbittorrent_credentials() {
  local desired_user="${QBITTORRENT_USER:-admin}"
  local desired_pass="${QBITTORRENT_PASSWORD:-}"

  if [[ -z "$desired_pass" ]]; then
    log_err "QBITTORRENT_PASSWORD não definido no .env"
    exit 1
  fi

  if qbittorrent_login "$desired_pass"; then
    log_ok "qBittorrent já usa as credenciais do .env"
    return 0
  fi

  log_info "Configurando credenciais do qBittorrent..."
  local temp_pass
  temp_pass="$(qbittorrent_temp_password)"
  if [[ -z "$temp_pass" ]]; then
    log_err "Não consegui descobrir a senha temporária do qBittorrent. Ajuste a Web UI manualmente e rode make configure novamente."
    exit 1
  fi

  qbittorrent_login "$temp_pass" || {
    log_err "Senha temporária do qBittorrent não funcionou"
    exit 1
  }

  local payload
  payload=$(QBT_USER="$desired_user" QBT_PASS="$desired_pass" python3 -c 'import json, os; print(json.dumps({"web_ui_username": os.environ["QBT_USER"], "web_ui_password": os.environ["QBT_PASS"]}))')

  curl -fsS -X POST "$(qbittorrent_base_url)/api/v2/app/setPreferences" \
    -b "$QBITTORRENT_COOKIE_JAR" \
    -c "$QBITTORRENT_COOKIE_JAR" \
    --data-urlencode "json=$payload" >/dev/null
  sleep 1

  qbittorrent_login "$desired_pass" || {
    log_err "Falha ao validar a nova senha do qBittorrent"
    exit 1
  }

  log_ok "qBittorrent configurado com as credenciais do .env"
}

# -----------------------------------------------------------------------------
# *Arr configuration
# -----------------------------------------------------------------------------

ensure_root_folder() {
  local service="$1"
  local port="$2"
  local api_key="$3"
  local path="$4"
  local base="http://127.0.0.1:${port}/api/v3"

  local existing
  existing=$(curl -sf "$base/rootfolder" -H "X-Api-Key: $api_key" \
    | python3 -c "import sys,json; paths={r['path'] for r in json.load(sys.stdin)}; print('yes' if '$path' in paths else 'no')")

  if [[ "$existing" == "yes" ]]; then
    log_ok "$service root folder já existe: $path"
    return 0
  fi

  curl -sf -X POST "$base/rootfolder" \
    -H "X-Api-Key: $api_key" \
    -H "Content-Type: application/json" \
    -d "{\"path\":\"$path\"}" >/dev/null

  log_ok "$service root folder criada: $path"
}

ensure_download_client() {
  local service="$1"
  local port="$2"
  local api_key="$3"
  local category="$4"
  local base="http://127.0.0.1:${port}/api/v3"

  local client_id
  client_id=$(curl -sf "$base/downloadclient" -H "X-Api-Key: $api_key" \
    | python3 -c "import sys,json; clients=json.load(sys.stdin); print(next((c['id'] for c in clients if c['name']=='qBittorrent'), ''))")

  local payload
  payload=$(WEBUI_PORT="$WEBUI_PORT" QBITTORRENT_USER="$QBITTORRENT_USER" QBITTORRENT_PASSWORD="$QBITTORRENT_PASSWORD" CATEGORY="$category" python3 <<'PY'
import json, os
print(json.dumps({
  "enable": True,
  "protocol": "torrent",
  "priority": 1,
  "removeCompletedDownloads": True,
  "removeFailedDownloads": True,
  "name": "qBittorrent",
  "implementation": "QBittorrent",
  "implementationName": "qBittorrent",
  "configContract": "QBittorrentSettings",
  "tags": [],
  "fields": [
    {"name": "host", "value": "qbittorrent"},
    {"name": "port", "value": int(os.environ["WEBUI_PORT"])},
    {"name": "useSsl", "value": False},
    {"name": "username", "value": os.environ["QBITTORRENT_USER"]},
    {"name": "password", "value": os.environ["QBITTORRENT_PASSWORD"]},
    {"name": "movieCategory" if os.environ["CATEGORY"].startswith("movies") else "tvCategory", "value": os.environ["CATEGORY"]},
  ],
}))
PY
)

  if [[ -n "$client_id" ]]; then
    payload=$(CLIENT_ID="$client_id" PAYLOAD="$payload" python3 -c "import json,os; p=json.loads(os.environ['PAYLOAD']); p['id']=int(os.environ['CLIENT_ID']); print(json.dumps(p))")
    curl -sf -X PUT "$base/downloadclient/$client_id" \
      -H "X-Api-Key: $api_key" \
      -H "Content-Type: application/json" \
      -d "$payload" >/dev/null
    log_ok "$service download client atualizado (qBittorrent)"
  else
    curl -sf -X POST "$base/downloadclient" \
      -H "X-Api-Key: $api_key" \
      -H "Content-Type: application/json" \
      -d "$payload" >/dev/null
    log_ok "$service download client criado (qBittorrent)"
  fi
}

ensure_prowlarr_app() {
  local app_json="$1"
  local prowlarr_key="$2"

  local payload
  payload=$(APP_JSON="$app_json" ROOT_DIR="$ROOT_DIR" python3 <<'PY'
import json, os, re

app = json.loads(os.environ["APP_JSON"])
config_path = os.path.join(os.environ["ROOT_DIR"], app["api_key_config"])
xml = open(config_path).read()
api_key = re.search(r"<ApiKey>([^<]+)</ApiKey>", xml).group(1)

payload = {
  "name": app["name"],
  "syncLevel": app["sync_level"],
  "implementation": app["implementation"],
  "implementationName": app["name"],
  "configContract": app["config_contract"],
  "tags": [],
  "enable": True,
  "fields": [
    {"name": "prowlarrUrl", "value": app["prowlarr_url"]},
    {"name": "baseUrl", "value": app["app_url"]},
    {"name": "apiKey", "value": api_key},
    {"name": "syncCategories", "value": app["sync_categories"]},
  ],
}
print(json.dumps(payload))
PY
)

  local app_name
  app_name=$(echo "$payload" | python3 -c "import sys,json; print(json.load(sys.stdin)['name'])")

  local app_id
  app_id=$(curl -sf "http://127.0.0.1:${PROWLARR_PORT:-9696}/api/v1/applications" \
    -H "X-Api-Key: $prowlarr_key" \
    | python3 -c "import sys,json; apps=json.load(sys.stdin); print(next((a['id'] for a in apps if a['name']=='$app_name'), ''))")

  if [[ -n "$app_id" ]]; then
    payload=$(APP_ID="$app_id" PAYLOAD="$payload" python3 -c "import json,os; p=json.loads(os.environ['PAYLOAD']); p['id']=int(os.environ['APP_ID']); print(json.dumps(p))")
    curl -sf -X PUT "http://127.0.0.1:${PROWLARR_PORT:-9696}/api/v1/applications/$app_id" \
      -H "X-Api-Key: $prowlarr_key" \
      -H "Content-Type: application/json" \
      -d "$payload" >/dev/null
    log_ok "Prowlarr app atualizada: $app_name"
  else
    curl -sf -X POST "http://127.0.0.1:${PROWLARR_PORT:-9696}/api/v1/applications" \
      -H "X-Api-Key: $prowlarr_key" \
      -H "Content-Type: application/json" \
      -d "$payload" >/dev/null
    log_ok "Prowlarr app criada: $app_name"
  fi
}

ensure_prowlarr_indexer_by_name() {
  local name="$1"
  local prowlarr_key="$2"
  local port="${PROWLARR_PORT:-9696}"

  local exists
  exists=$(curl -sf "http://127.0.0.1:${port}/api/v1/indexer" -H "X-Api-Key: $prowlarr_key" \
    | python3 -c "import sys,json; names={i['name'] for i in json.load(sys.stdin)}; print('yes' if '$name' in names else 'no')")

  if [[ "$exists" == "yes" ]]; then
    log_ok "Prowlarr indexer já existe: $name"
    return 0
  fi

  local payload
  payload=$(NAME="$name" PORT="$port" KEY="$prowlarr_key" python3 <<'PY'
import json, os, urllib.request

name = os.environ["NAME"]
port = os.environ["PORT"]
api_key = os.environ["KEY"]
base = f"http://127.0.0.1:{port}/api/v1"

req = urllib.request.Request(
    f"{base}/indexer/schema",
    headers={"X-Api-Key": api_key},
)
with urllib.request.urlopen(req, timeout=30) as resp:
    schemas = json.loads(resp.read().decode())

schema = next((s for s in schemas if s.get("name") == name), None)
if not schema:
    raise SystemExit(f"schema not found: {name}")

schema["name"] = name
schema["appProfileId"] = 1
schema["priority"] = 25
for field in schema.get("fields", []):
    if field["name"] == "definitionFile":
        pass
print(json.dumps(schema))
PY
) || {
    log_warn "Não foi possível adicionar indexer automaticamente: $name (adicione manualmente no Prowlarr)"
    return 0
  }

  if curl -sf -X POST "http://127.0.0.1:${port}/api/v1/indexer" \
    -H "X-Api-Key: $prowlarr_key" \
    -H "Content-Type: application/json" \
    -d "$payload" >/dev/null; then
    log_ok "Prowlarr indexer criado: $name"
  else
    log_warn "Falha ao criar indexer $name — adicione manualmente no Prowlarr"
  fi
}

sync_prowlarr_indexers() {
  local prowlarr_key="$1"
  curl -sf -X POST "http://127.0.0.1:${PROWLARR_PORT:-9696}/api/v1/command" \
    -H "X-Api-Key: $prowlarr_key" \
    -H "Content-Type: application/json" \
    -d '{"name":"ApplicationIndexerSync","forceSync":true}' >/dev/null || true
  log_ok "Sync de indexadores Prowlarr → *Arr disparado"
}

configure_arr_stack() {
  log_info "Configurando stack *Arr..."

  local prowlarr_key radarr_key sonarr_key
  prowlarr_key=$(get_api_key "prowlarr/config/config.xml")
  radarr_key=$(get_api_key "radarr/config/config.xml")
  sonarr_key=$(get_api_key "sonarr/config/config.xml")

  log_info "Configurando root folders..."
  ensure_root_folder "Radarr" "${RADARR_PORT:-7878}" "$radarr_key" "/movies"
  ensure_root_folder "Sonarr" "${SONARR_PORT:-8989}" "$sonarr_key" "/tv"

  log_info "Configurando download clients..."
  ensure_download_client "Radarr" "${RADARR_PORT:-7878}" "$radarr_key" "movies-radarr"
  ensure_download_client "Sonarr" "${SONARR_PORT:-8989}" "$sonarr_key" "tv-sonarr"

  log_info "Configurando Prowlarr apps..."
  local apps_json
  apps_json=$(read_config "prowlarr_apps")
  while IFS= read -r app; do
    ensure_prowlarr_app "$app" "$prowlarr_key"
  done < <(APPS_JSON="$apps_json" python3 -c "import json,os; [print(json.dumps(a)) for a in json.loads(os.environ['APPS_JSON'])]")

  log_info "Verificando indexadores no Prowlarr..."
  local indexers_json
  indexers_json=$(read_config "prowlarr_indexers")
  while IFS= read -r indexer; do
    ensure_prowlarr_indexer_by_name "$indexer" "$prowlarr_key"
  done < <(INDEXERS_JSON="$indexers_json" python3 -c "import json,os; [print(i) for i in json.loads(os.environ['INDEXERS_JSON'])]")

  sync_prowlarr_indexers "$prowlarr_key"

  log_info "Disparando busca para conteúdo monitorado sem arquivo..."
  if [[ -f "$ROOT_DIR/scripts/search-missing.sh" ]]; then
    bash "$ROOT_DIR/scripts/search-missing.sh" || log_warn "Busca por conteúdo faltando falhou (verifique logs acima)"
  else
    log_warn "scripts/search-missing.sh ausente; pulando busca automática"
  fi
}

# -----------------------------------------------------------------------------
# Bazarr configuration
# -----------------------------------------------------------------------------

BAZARR_PORT="${BAZARR_PORT:-6767}"
BAZARR_CONFIG_DIR="$ROOT_DIR/bazarr/config"
BAZARR_CONFIG_YAML="$BAZARR_CONFIG_DIR/config/config.yaml"
BAZARR_DB_FILE="$BAZARR_CONFIG_DIR/db/bazarr.db"
BAZARR_PROFILE_NAME="Português"

bazarr_api_key() {
  if [[ ! -f "$BAZARR_CONFIG_YAML" ]]; then
    log_err "Bazarr ainda não criou config.yaml. Suba o container e tente novamente."
    exit 1
  fi
  python3 -c "import yaml; print(yaml.safe_load(open('$BAZARR_CONFIG_YAML'))['auth']['apikey'])"
}

wait_for_bazarr() {
  local key="$1" user="${2:-admin}" password="${3:-ClssStream2026!}" max_attempts="${4:-30}"
  for ((i = 1; i <= max_attempts; i++)); do
    if docker exec bazarr curl -sf "http://localhost:6767/api/system/ping" \
      -H "X-API-KEY: $key" -u "$user:$password" >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
  done
  log_err "Bazarr não respondeu após $((max_attempts * 2))s"
  return 1
}

configure_bazarr_yaml() {
  local radarr_key="$1" sonarr_key="$2"
  python3 - "$BAZARR_CONFIG_YAML" "$radarr_key" "$sonarr_key" "$BAZARR_PROFILE_NAME" <<'PY'
import sys, yaml, os

config_path = sys.argv[1]
radarr_key = sys.argv[2]
sonarr_key = sys.argv[3]
profile_name = sys.argv[4]

with open(config_path) as f:
    cfg = yaml.safe_load(f) or {}

# Enable integrations
cfg['general']['use_radarr'] = True
cfg['general']['use_sonarr'] = True
cfg['general']['enabled_providers'] = ['opensubtitlescom', 'legendasdivx', 'legendasnet']
cfg['general']['movie_default_enabled'] = True
cfg['general']['serie_default_enabled'] = True
cfg['general']['movie_default_profile'] = profile_name
cfg['general']['serie_default_profile'] = profile_name

# Authentication (basic auth because Bazarr resets forms type)
auth_password = os.environ.get('COMMON_PASSWORD', 'ClssStream2026!')
auth_user = os.environ.get('COMMON_USER', 'admin')
cfg['auth']['type'] = 'basic'
cfg['auth']['username'] = auth_user
cfg['auth']['password'] = auth_password

# Radarr/Sonarr connection
cfg['radarr']['ip'] = 'radarr'
cfg['radarr']['apikey'] = radarr_key
cfg['radarr']['port'] = 7878
cfg['sonarr']['ip'] = 'sonarr'
cfg['sonarr']['apikey'] = sonarr_key
cfg['sonarr']['port'] = 8989

with open(config_path, 'w') as f:
    yaml.safe_dump(cfg, f, default_flow_style=False, sort_keys=False)
PY
}

ensure_bazarr_language_profile() {
  local db="$1"
  python3 - "$db" "$BAZARR_PROFILE_NAME" <<'PY'
import sqlite3, json, sys

db_path = sys.argv[1]
profile_name = sys.argv[2]
conn = sqlite3.connect(db_path)
c = conn.cursor()

c.execute("SELECT profileId FROM table_languages_profiles WHERE name = ?", (profile_name,))
row = c.fetchone()
if row:
    print(row[0])
    conn.close()
    sys.exit(0)

items = json.dumps([
    {"id": 1, "language": "pob", "audio": "False", "hi": "False", "forced": "False"},
    {"id": 2, "language": "por", "audio": "False", "hi": "False", "forced": "False"},
])
c.execute(
    "INSERT INTO table_languages_profiles (name, cutoff, originalFormat, items) VALUES (?, ?, ?, ?)",
    (profile_name, None, 0, items),
)
conn.commit()
print(c.lastrowid)
conn.close()
PY
}

bazarr_is_already_configured() {
  [[ ! -f "$BAZARR_CONFIG_YAML" ]] && return 1
  python3 - "$BAZARR_CONFIG_YAML" "$BAZARR_PROFILE_NAME" <<'PY'
import sys, yaml
cfg = yaml.safe_load(open(sys.argv[1])) or {}
profile = sys.argv[2]
ok = (
    cfg.get('general', {}).get('use_radarr') is True and
    cfg.get('general', {}).get('use_sonarr') is True and
    cfg.get('general', {}).get('movie_default_profile') == profile and
    cfg.get('general', {}).get('serie_default_profile') == profile and
    cfg.get('radarr', {}).get('ip') == 'radarr' and
    cfg.get('sonarr', {}).get('ip') == 'sonarr'
)
print('yes' if ok else 'no')
PY
}

# -----------------------------------------------------------------------------
# Seerr configuration
# -----------------------------------------------------------------------------

SEERR_URL="${SEERR_URL:-http://localhost:5055}"
SEERR_PUBLIC_URL="${SEERR_PUBLIC_URL:-}"
JELLYFIN_INTERNAL_HOST="${JELLYFIN_INTERNAL_HOST:-jellyfin}"
JELLYFIN_INTERNAL_PORT="${JELLYFIN_INTERNAL_PORT:-8096}"
JELLYFIN_URL_BASE="${JELLYFIN_URL_BASE:-}"
RADARR_INTERNAL_HOST="${RADARR_INTERNAL_HOST:-radarr}"
RADARR_INTERNAL_PORT="${RADARR_INTERNAL_PORT:-7878}"
RADARR_ROOT_FOLDER="${RADARR_ROOT_FOLDER:-/movies}"
SONARR_INTERNAL_HOST="${SONARR_INTERNAL_HOST:-sonarr}"
SONARR_INTERNAL_PORT="${SONARR_INTERNAL_PORT:-8989}"
SONARR_ROOT_FOLDER="${SONARR_ROOT_FOLDER:-/tv}"
SEERR_INITIALIZE="${SEERR_INITIALIZE:-true}"

COOKIE_JAR="$(mktemp)"
trap 'rm -f "$COOKIE_JAR" "$QBITTORRENT_COOKIE_JAR"' EXIT

seerr_api() {
  local method="$1"
  local path="$2"
  local data="${3:-}"

  if [[ -n "$data" ]]; then
    curl -fsS -X "$method" "$SEERR_URL/api/v1$path" \
      -b "$COOKIE_JAR" -c "$COOKIE_JAR" \
      -H 'Content-Type: application/json' \
      -d "$data"
  else
    curl -fsS -X "$method" "$SEERR_URL/api/v1$path" \
      -b "$COOKIE_JAR" -c "$COOKIE_JAR" \
      -H 'Content-Type: application/json'
  fi
}

seerr_api_public() {
  curl -fsS "$SEERR_URL/api/v1$1"
}

arr_api_key() {
  local service="$1"
  local config_path="$ROOT_DIR/$service/config/config.xml"

  if [[ ! -f "$config_path" ]]; then
    log_err "API key do $service não encontrada em $config_path. Suba o container e aguarde a criação do config.xml."
    exit 1
  fi

  local key
  key="$(api_key_from_config "$config_path")"
  if [[ -z "$key" ]]; then
    log_err "API key vazia em $config_path"
    exit 1
  fi
  printf '%s' "$key"
}

SEERR_DB_FILE="$ROOT_DIR/seerr/config/db/db.sqlite3"

seerr_user_count() {
  python3 - "$SEERR_DB_FILE" <<'SEERRPY'
import sqlite3, sys
conn = sqlite3.connect(sys.argv[1])
cur = conn.cursor()
print(cur.execute('SELECT COUNT(*) FROM user').fetchone()[0])
conn.close()
SEERRPY
}

seed_seerr_local_admin() {
  local email="${SEERR_ADMIN_EMAIL:-${COMMON_USER}@local}"
  local username="${SEERR_ADMIN_USERNAME:-${COMMON_USER}}"
  local password="${SEERR_ADMIN_PASSWORD:-${COMMON_PASSWORD:-}}"

  if [[ -z "$password" ]]; then
    log_err "SEERR_ADMIN_PASSWORD/COMMON_PASSWORD não definido no .env"
    exit 1
  fi

  if [[ "$(seerr_user_count)" != "0" ]]; then
    return 0
  fi

  local password_hash
  password_hash="$(docker exec -e SEERR_BCRYPT_PASSWORD="$password" seerr node -e 'const bcrypt=require("bcrypt"); bcrypt.hash(process.env.SEERR_BCRYPT_PASSWORD, 12).then((hash) => console.log(hash))')"

  python3 - "$SEERR_DB_FILE" "$email" "$username" "$password_hash" <<'SEERRPY'
import sqlite3, sys

db_path, email, username, password_hash = sys.argv[1:]
conn = sqlite3.connect(db_path)
cur = conn.cursor()
cur.execute(
    'INSERT INTO user (id, email, username, permissions, avatar, password, userType) VALUES (1, ?, ?, 2, ?, ?, 2)',
    (email.lower(), username, '', password_hash),
)
conn.commit()
conn.close()
SEERRPY

  log_ok "Admin inicial do Seerr criado: $email"
}

login_seerr() {
  if [[ -n "${SEERR_ADMIN_EMAIL:-}" && -n "${SEERR_ADMIN_PASSWORD:-}" ]]; then
    log_info "Autenticando no Seerr com conta local/admin: $SEERR_ADMIN_EMAIL"
    if seerr_api POST /auth/local "$(jq -n --arg email "$SEERR_ADMIN_EMAIL" --arg password "$SEERR_ADMIN_PASSWORD" '{email:$email,password:$password}')" >/dev/null; then
      return 0
    fi

    if [[ "$(seerr_user_count)" == "0" ]]; then
      log_warn "Seerr ainda não tem usuário local; criando admin inicial no banco"
      seed_seerr_local_admin
      seerr_api POST /auth/local "$(jq -n --arg email "$SEERR_ADMIN_EMAIL" --arg password "$SEERR_ADMIN_PASSWORD" '{email:$email,password:$password}')" >/dev/null
      return 0
    fi

    log_warn "Login local do Seerr falhou; tentando via Jellyfin"
  fi

  if [[ -n "${JELLYFIN_ADMIN_USER:-}" && -n "${JELLYFIN_ADMIN_PASSWORD:-}" ]]; then
    local email="${JELLYFIN_ADMIN_EMAIL:-${SEERR_ADMIN_EMAIL:-${JELLYFIN_ADMIN_USER}@local}}"
    local jellyfin_ip=""
    local payload

    log_info "Autenticando no Seerr via Jellyfin admin: $JELLYFIN_ADMIN_USER"

    if [[ -f "$ROOT_DIR/seerr/config/settings.json" ]]; then
      jellyfin_ip="$(jq -r '.jellyfin.ip // ""' "$ROOT_DIR/seerr/config/settings.json")"
    fi

    if [[ -n "$jellyfin_ip" ]]; then
      payload="$(jq -n \
        --arg username "$JELLYFIN_ADMIN_USER" \
        --arg password "$JELLYFIN_ADMIN_PASSWORD" \
        --arg email "$email" \
        '{username:$username,password:$password,email:$email,serverType:2}')"
    else
      payload="$(jq -n \
        --arg username "$JELLYFIN_ADMIN_USER" \
        --arg password "$JELLYFIN_ADMIN_PASSWORD" \
        --arg hostname "$JELLYFIN_INTERNAL_HOST" \
        --arg urlBase "$JELLYFIN_URL_BASE" \
        --arg email "$email" \
        --argjson port "$JELLYFIN_INTERNAL_PORT" \
        '{username:$username,password:$password,hostname:$hostname,port:$port,useSsl:false,urlBase:$urlBase,email:$email,serverType:2}')"
    fi

    seerr_api POST /auth/jellyfin "$payload" >/dev/null
    return 0
  fi

  log_err "Informe SEERR_ADMIN_EMAIL/SEERR_ADMIN_PASSWORD ou JELLYFIN_ADMIN_USER/JELLYFIN_ADMIN_PASSWORD no .env."
  exit 1
}

merge_seerr_main_settings() {
  local current payload
  current="$(seerr_api GET /settings/main)"
  payload="$(jq \
    --arg appUrl "$SEERR_PUBLIC_URL" \
    'del(.apiKey)
    | . + {
      localLogin: true,
      mediaServerLogin: true,
      mediaServerType: 2,
      partialRequestsEnabled: true
    }
    | if $appUrl != "" then .applicationUrl = $appUrl else . end' <<<"$current")"
  seerr_api POST /settings/main "$payload" >/dev/null
  log_ok "Configurações principais do Seerr atualizadas"
}

configure_seerr_jellyfin() {
  local current payload libraries enable_ids
  current="$(seerr_api GET /settings/jellyfin)"

  payload="$(jq \
    --arg ip "$JELLYFIN_INTERNAL_HOST" \
    --arg urlBase "$JELLYFIN_URL_BASE" \
    --arg external "${JELLYFIN_EXTERNAL_URL:-}" \
    --argjson port "$JELLYFIN_INTERNAL_PORT" \
    'del(.libraries, .serverId, .apiKey, .name)
    | . + {ip:$ip, port:$port, useSsl:false, urlBase:$urlBase, externalHostname:$external}' <<<"$current")"

  seerr_api POST /settings/jellyfin "$payload" >/dev/null

  if ! libraries="$(seerr_api GET '/settings/jellyfin/library?sync=true')"; then
    log_warn "Jellyfin ainda não está pronto no Seerr; pulando sincronização de bibliotecas"
    return 0
  fi

  enable_ids="$(jq -r '[.[] | select(.type == "movie" or .type == "show" or .type == "tvshows") | .id] | join(",")' <<<"$libraries")"

  if [[ -n "$enable_ids" ]]; then
    seerr_api GET "/settings/jellyfin/library?enable=$enable_ids" >/dev/null
    log_ok "Jellyfin configurado no Seerr e bibliotecas habilitadas"
  else
    log_warn "Jellyfin configurado no Seerr, mas nenhuma biblioteca de filmes/séries foi encontrada para habilitar"
  fi
}

first_profile_and_folder() {
  local service="$1"
  local test_payload="$2"
  local root_folder="$3"
  local profile_override="${4:-}"

  local result profile_id profile_name directory language_profile_id
  result="$(seerr_api POST "/settings/$service/test" "$test_payload")"

  if [[ -n "$profile_override" ]]; then
    profile_id="$profile_override"
    profile_name="$(jq -r --argjson id "$profile_id" '.profiles[] | select(.id == $id) | .name' <<<"$result" | head -1)"
  else
    profile_id="$(jq -r '.profiles[0].id' <<<"$result")"
    profile_name="$(jq -r '.profiles[0].name' <<<"$result")"
  fi

  directory="$(jq -r --arg path "$root_folder" '.rootFolders[] | select(.path == $path) | .path' <<<"$result" | head -1)"
  if [[ -z "$directory" ]]; then
    directory="$(jq -r '.rootFolders[0].path // empty' <<<"$result")"
  fi

  if [[ -z "$profile_id" || "$profile_id" == "null" || -z "$profile_name" || "$profile_name" == "null" ]]; then
    log_err "Nenhum profile encontrado no $service"
    exit 1
  fi

  if [[ -z "$directory" || "$directory" == "null" ]]; then
    log_err "Nenhum root folder encontrado no $service"
    exit 1
  fi

  language_profile_id="$(jq -r '.languageProfiles[0].id // 1' <<<"$result")"
  jq -n \
    --argjson profileId "$profile_id" \
    --arg profileName "$profile_name" \
    --arg directory "$directory" \
    --argjson languageProfileId "${SONARR_LANGUAGE_PROFILE_ID:-$language_profile_id}" \
    '{profileId:$profileId, profileName:$profileName, directory:$directory, languageProfileId:$languageProfileId}'
}

upsert_seerr_radarr() {
  local api_key test_payload selection payload existing_id method path
  api_key="${RADARR_API_KEY:-$(arr_api_key radarr)}"
  test_payload="$(jq -n \
    --arg hostname "$RADARR_INTERNAL_HOST" \
    --arg apiKey "$api_key" \
    --argjson port "$RADARR_INTERNAL_PORT" \
    '{hostname:$hostname,port:$port,apiKey:$apiKey,useSsl:false,baseUrl:""}')"
  selection="$(first_profile_and_folder radarr "$test_payload" "$RADARR_ROOT_FOLDER" "${RADARR_PROFILE_ID:-}")"

  payload="$(jq -n \
    --arg hostname "$RADARR_INTERNAL_HOST" \
    --arg apiKey "$api_key" \
    --arg external "${RADARR_EXTERNAL_URL:-}" \
    --argjson port "$RADARR_INTERNAL_PORT" \
    --argjson profileId "$(jq '.profileId' <<<"$selection")" \
    --arg profileName "$(jq -r '.profileName' <<<"$selection")" \
    --arg directory "$(jq -r '.directory' <<<"$selection")" \
    '{name:"Radarr",hostname:$hostname,port:$port,apiKey:$apiKey,useSsl:false,baseUrl:"",activeProfileId:$profileId,activeProfileName:$profileName,activeDirectory:$directory,is4k:false,minimumAvailability:"released",isDefault:true,externalUrl:$external,syncEnabled:true,preventSearch:false}')"

  existing_id="$(seerr_api GET /settings/radarr | jq -r --arg host "$RADARR_INTERNAL_HOST" '.[] | select(.hostname == $host and .is4k == false) | .id' | head -1)"
  if [[ -n "$existing_id" ]]; then
    method=PUT
    path="/settings/radarr/$existing_id"
  else
    method=POST
    path=/settings/radarr
  fi

  seerr_api "$method" "$path" "$payload" >/dev/null
  log_ok "Radarr configurado no Seerr usando $RADARR_INTERNAL_HOST:$RADARR_INTERNAL_PORT"
}

upsert_seerr_sonarr() {
  local api_key test_payload selection payload existing_id method path
  api_key="${SONARR_API_KEY:-$(arr_api_key sonarr)}"
  test_payload="$(jq -n \
    --arg hostname "$SONARR_INTERNAL_HOST" \
    --arg apiKey "$api_key" \
    --argjson port "$SONARR_INTERNAL_PORT" \
    '{hostname:$hostname,port:$port,apiKey:$apiKey,useSsl:false,baseUrl:""}')"
  selection="$(first_profile_and_folder sonarr "$test_payload" "$SONARR_ROOT_FOLDER" "${SONARR_PROFILE_ID:-}")"

  payload="$(jq -n \
    --arg hostname "$SONARR_INTERNAL_HOST" \
    --arg apiKey "$api_key" \
    --arg external "${SONARR_EXTERNAL_URL:-}" \
    --argjson port "$SONARR_INTERNAL_PORT" \
    --argjson profileId "$(jq '.profileId' <<<"$selection")" \
    --arg profileName "$(jq -r '.profileName' <<<"$selection")" \
    --arg directory "$(jq -r '.directory' <<<"$selection")" \
    --argjson languageProfileId "$(jq '.languageProfileId' <<<"$selection")" \
    '{name:"Sonarr",hostname:$hostname,port:$port,apiKey:$apiKey,useSsl:false,baseUrl:"",activeProfileId:$profileId,activeProfileName:$profileName,activeDirectory:$directory,activeLanguageProfileId:$languageProfileId,activeAnimeProfileId:null,activeAnimeLanguageProfileId:null,activeAnimeProfileName:null,activeAnimeDirectory:null,is4k:false,enableSeasonFolders:true,isDefault:true,externalUrl:$external,syncEnabled:true,preventSearch:false}')"

  existing_id="$(seerr_api GET /settings/sonarr | jq -r --arg host "$SONARR_INTERNAL_HOST" '.[] | select(.hostname == $host and .is4k == false) | .id' | head -1)"
  if [[ -n "$existing_id" ]]; then
    method=PUT
    path="/settings/sonarr/$existing_id"
  else
    method=POST
    path=/settings/sonarr
  fi

  seerr_api "$method" "$path" "$payload" >/dev/null
  log_ok "Sonarr configurado no Seerr usando $SONARR_INTERNAL_HOST:$SONARR_INTERNAL_PORT"
}

initialize_seerr() {
  if [[ "$SEERR_INITIALIZE" != "true" ]]; then
    log_warn "Inicialização final do Seerr pulada porque SEERR_INITIALIZE=$SEERR_INITIALIZE"
    return 0
  fi

  seerr_api POST /settings/initialize '{}' >/dev/null
  log_ok "Seerr marcado como inicializado"
}

configure_bazarr() {
  log_info "Configurando Bazarr..."

  local radarr_key sonarr_key bazarr_key profile_id
  radarr_key=$(api_key_from_config "$ROOT_DIR/radarr/config/config.xml")
  sonarr_key=$(api_key_from_config "$ROOT_DIR/sonarr/config/config.xml")

  if [[ -z "$radarr_key" || -z "$sonarr_key" ]]; then
    log_err "API keys do Radarr e/ou Sonarr não encontradas. Execute make configure após subir os containers."
    return 1
  fi

  local auth_user auth_pass
  auth_user="${COMMON_USER:-admin}"
  auth_pass="${COMMON_PASSWORD:-ClssStream2026!}"

  if [[ ! -f "$BAZARR_CONFIG_YAML" ]]; then
    log_info "Bazarr ainda não inicializou. Subindo para criar configuração..."
    docker compose up -d bazarr
    bazarr_key=$(bazarr_api_key)
    wait_for_bazarr "$bazarr_key" "$auth_user" "$auth_pass"
  else
    bazarr_key=$(bazarr_api_key)
  fi

  if [[ "$(bazarr_is_already_configured)" == "yes" ]]; then
    log_ok "Bazarr já configurado para Radarr/Sonarr e perfil '$BAZARR_PROFILE_NAME'"
  else
    log_info "Configurando Bazarr (necessita parar o container)..."
    docker stop bazarr >/dev/null

    mkdir -p "$BAZARR_CONFIG_DIR/backup"
    cp "$BAZARR_CONFIG_YAML" "$BAZARR_CONFIG_DIR/backup/config.yaml.$(date +%Y%m%d%H%M%S).bak" 2>/dev/null || true
    cp "$BAZARR_DB_FILE" "$BAZARR_CONFIG_DIR/backup/bazarr.db.$(date +%Y%m%d%H%M%S).bak" 2>/dev/null || true

    configure_bazarr_yaml "$radarr_key" "$sonarr_key"
    profile_id=$(ensure_bazarr_language_profile "$BAZARR_DB_FILE")
    log_ok "Perfil de idioma '$BAZARR_PROFILE_NAME' criado/atualizado (ID: $profile_id)"

    docker start bazarr >/dev/null
    wait_for_bazarr "$bazarr_key" "$auth_user" "$auth_pass"
    log_ok "Bazarr reiniciado e configurado"
  fi

  log_info "Disparando sync com Radarr e Sonarr..."
  docker exec bazarr curl -sf -X POST "http://localhost:6767/api/system/tasks?taskid=update_movies" \
    -H "X-API-KEY: $bazarr_key" -u "$auth_user:$auth_pass" >/dev/null || log_warn "Falha ao disparar sync de filmes"
  docker exec bazarr curl -sf -X POST "http://localhost:6767/api/system/tasks?taskid=update_series" \
    -H "X-API-KEY: $bazarr_key" -u "$auth_user:$auth_pass" >/dev/null || log_warn "Falha ao disparar sync de séries"
  log_ok "Sync Bazarr → Radarr/Sonarr disparado"
}

configure_seerr() {
  log_info "Configurando Seerr..."

  wait_for_http "$SEERR_URL/api/v1/status" "Seerr" 30
  seerr_api_public /settings/public >/dev/null
  login_seerr
  merge_seerr_main_settings
  configure_seerr_jellyfin
  upsert_seerr_radarr
  upsert_seerr_sonarr
  initialize_seerr
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------

main() {
  if [[ "${1:-}" == "--bazarr-only" ]]; then
    log_info "Executando apenas configuração do Bazarr..."
  wait_for_http "http://127.0.0.1:${BAZARR_PORT:-6767}/api/system/ping" "Bazarr"
    configure_bazarr
    return 0
  fi

  log_info "Aguardando serviços..."
  wait_for_http "http://127.0.0.1:${PROWLARR_PORT:-9696}" "Prowlarr"
  wait_for_http "http://127.0.0.1:${RADARR_PORT:-7878}" "Radarr"
  wait_for_http "http://127.0.0.1:${SONARR_PORT:-8989}" "Sonarr"
  wait_for_http "http://127.0.0.1:${WEBUI_PORT:-8082}" "qBittorrent"
  wait_for_http "http://127.0.0.1:${BAZARR_PORT:-6767}/api/system/ping" "Bazarr"
  wait_for_http "$SEERR_URL/api/v1/status" "Seerr" 30

  ensure_qbittorrent_credentials
  configure_arr_stack
  configure_bazarr
  configure_seerr

  echo ""
  log_ok "Configuração automatizada concluída."
  echo ""
  echo "Dicas:"
  echo "  • Plex: bibliotecas /tv e /movies + PLEX_CLAIM no .env"
  echo "  • Radarr/Sonarr não têm 'Search on add' global. Ao adicionar pela UI, marque"
  echo "    'Start search for missing movie'. No Seerr use 'Request and Search'."
  echo "  • Firewall/Cloud: abrir portas ou usar SSH tunnel"
}

main "$@"
