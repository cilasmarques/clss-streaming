# CLSS Streaming — Media Server Stack

Servidor de mídia automatizado baseado na stack *Arr, com download via torrent, organização de biblioteca e streaming para dispositivos locais e remotos.

## Visão geral

O sistema segue um pipeline totalmente automatizado:

```
Prowlarr (indexadores)
    ↓ sync automático
Radarr (filmes) / Sonarr (séries)
    ↓ envia torrent
qBittorrent (download em /downloads)
    ↓ importa e renomeia
/media/movies  ou  /media/tv
    ↓ legendas automáticas
Bazarr (legendas PT-BR)
    ↓ scan da biblioteca
Plex / Jellyfin (streaming)
```

Após a configuração inicial, basta adicionar um filme no Radarr ou uma série no Sonarr — o resto acontece sozinho.

---

## Serviços e portas

| Serviço | Porta | Função |
|---------|-------|--------|
| **Plex** | 32400 | Streaming (host network) |
| **Jellyfin** | 8096 | Streaming alternativo (acesso remoto gratuito) |
| **Sonarr** | 8989 | Gestão de séries de TV |
| **Radarr** | 7878 | Gestão de filmes |
| **qBittorrent** | 8082 | Cliente de download |
| **Prowlarr** | 9696 | Gestor central de indexadores |
| **Bazarr** | 6767 | Download automático de legendas |
| **Seerr** | 5055 | Gestor de requisições de filmes/séries |

Todas as portas são configuráveis via `.env`.

---

## Estrutura de diretórios

```
clss-streaming/
├── docker-compose.yml       # Definição dos containers
├── .env                     # Variáveis de ambiente (não versionado)
├── .env.example             # Template das variáveis
├── Makefile                 # Comandos: make up/setup/configure/down
├── scripts/
│   ├── setup.sh             # Cria pastas e .env inicial
│   ├── configure.sh         # Automação pós-deploy (*Arr + Seerr + Bazarr)
│   ├── configure-bazarr.sh  # Configura apenas o Bazarr (legendas)
│   ├── search-missing.sh    # Busca conteúdo monitorado sem arquivo
│   └── arr-stack.json       # Configuração declarativa da stack *Arr
├── media/
│   ├── tv/                  # Destino final — séries
│   └── movies/              # Destino final — filmes
├── downloads/               # Downloads temporários (partilhado)
├── plex/config/             # Config Plex (persistente, gitignored)
├── jellyfin/config/
├── sonarr/config/
├── radarr/config/
├── qbittorrent/config/
├── prowlarr/config/
└── bazarr/config/           # Config Bazarr (legendas)
```

### Mapeamento de volumes (dentro dos containers)

| Caminho no container | Serviços | Função |
|---------------------|----------|--------|
| `/downloads` | Sonarr, Radarr, qBittorrent | Pasta de download partilhada |
| `/movies` | Radarr, Plex | Biblioteca de filmes |
| `/tv` | Sonarr, Plex | Biblioteca de séries |
| `/data/movies` | Jellyfin | Biblioteca de filmes |
| `/data/tvshows` | Jellyfin | Biblioteca de séries |

---

## Variáveis de ambiente

Copie `.env.example` para `.env` e ajuste:

| Variável | Descrição | Valor atual |
|----------|-----------|-------------|
| `PUID` / `PGID` | Permissões de ficheiros nos containers | `1001` |
| `TZ` | Fuso horário (agendamento Sonarr/Radarr) | `America/Sao_Paulo` |
| `PLEX_CLAIM` | Token de ativação Plex ([plex.tv/claim](https://www.plex.tv/claim)) | Definir antes do primeiro start |
| `WEBUI_PORT` | Porta Web UI do qBittorrent | `8082` |
| `QBITTORRENT_USER` | Utilizador qBittorrent | `admin` |
| `QBITTORRENT_PASSWORD` | Password qBittorrent | Definir no `.env` |
| `QBITTORRENT_PEER_PORT` | Porta peer BitTorrent (TCP+UDP) | `6881` |
| `SONARR_PORT` | Porta Web UI Sonarr | `8989` |
| `RADARR_PORT` | Porta Web UI Radarr | `7878` |
| `PROWLARR_PORT` | Porta Web UI Prowlarr | `9696` |
| `JELLYFIN_PORT` | Porta Web UI Jellyfin | `8096` |
| `JELLYFIN_PUBLISHED_SERVER_URL` | URL pública para clientes remotos Jellyfin | Opcional |

---

## Deploy do zero

```bash
# 1. Estrutura e .env
make setup
nano .env   # PLEX_CLAIM, passwords, etc.

# 2. Subir containers
make up

# 3. Configurar toda a stack automaticamente (após containers criarem config.xml)
make configure
```

O script `configure.sh` é **idempotente** — pode ser executado várias vezes sem duplicar configurações. Ele configura Prowlarr, Radarr, Sonarr, qBittorrent, Jellyfin (via Seerr) e Seerr.

---

## O que é automatizado

O ficheiro `scripts/arr-stack.json` define o comportamento e o script `scripts/configure.sh` aplica via API:

| Configuração | Detalhe |
|--------------|---------|
| **Root folders** | Radarr → `/movies`, Sonarr → `/tv` |
| **Download client** | qBittorrent em `qbittorrent:8082` com categorias `movies-radarr` e `tv-sonarr` |
| **Prowlarr → Radarr** | `http://prowlarr:9696` ↔ `http://radarr:7878`, Full Sync |
| **Prowlarr → Sonarr** | `http://prowlarr:9696` ↔ `http://sonarr:8989`, Full Sync |
| **Indexadores** | YTS, The Pirate Bay (se disponíveis no schema) |
| **Sync de indexadores** | Disparo automático Prowlarr → Radarr/Sonarr |
| **Busca por conteúdo faltando** | `make search-missing` dispara busca em filmes/séries monitorados sem arquivo |
| **Legendas automáticas** | Bazarr conectado ao Radarr/Sonarr, baixa legendas em português |
| **Seerr → Jellyfin** | `http://jellyfin:8096`, bibliotecas habilitadas |
| **Seerr → Radarr/Sonarr** | `http://radarr:7878` / `http://sonarr:8989` |

Credenciais do qBittorrent são lidas do `.env` (`QBITTORRENT_USER`, `QBITTORRENT_PASSWORD`).

API keys dos serviços *Arr são lidas automaticamente dos respetivos `config.xml` (gerados na primeira execução dos containers).

---

## O que é manual (primeira vez)

| Serviço | Ação |
|---------|------|
| **Plex** | Gerar `PLEX_CLAIM`, adicionar bibliotecas `/tv` e `/movies` |
| **Firewall** | Abrir portas na VM e Oracle Cloud Security List, ou usar SSH tunnel |
| **Indexadores** | Adicionar mais fontes no Prowlarr se as automáticas falharem |
| **Legendas** | Bazarr já configura PT-BR automaticamente; providers podem precisar de login |

---

## Configuração aplicada nesta instalação

### Infraestrutura
- VM Oracle Cloud (IP público `163.176.132.214`)
- Firewall da VM: apenas porta 22 aberta por defeito
- Timezone: Brasília (`America/Sao_Paulo`)
- Docker Compose com 7 serviços: Plex, Jellyfin, Sonarr, Radarr, qBittorrent, Prowlarr, Seerr

### Rede Docker (regra crítica)

Entre containers, **nunca usar `localhost`**. Usar sempre os nomes dos containers:

| De | Para | URL correta |
|----|------|-------------|
| Prowlarr | Radarr | `http://radarr:7878` |
| Prowlarr | Sonarr | `http://sonarr:8989` |
| Radarr/Sonarr | qBittorrent | `qbittorrent:8082` |
| Radarr/Sonarr | Prowlarr | `http://prowlarr:9696` |

`localhost` só é usado no **browser do utilizador** (ou via SSH tunnel).

### Prowlarr
- Indexadores: The Pirate Bay, YTS
- Apps ligadas: Radarr (Full Sync), Sonarr (Full Sync)
- URLs internas com nomes de container (não localhost)

### Radarr
- Root folder: `/movies`
- Download client: qBittorrent (`movies-radarr`)
- Indexadores sincronizados via Prowlarr (ex.: YTS)

### Sonarr
- Root folder: `/tv`
- Download client: qBittorrent (`tv-sonarr`)
- Indexadores sincronizados via Prowlarr

### Bazarr
- Sincroniza com Radarr (`radarr:7878`) e Sonarr (`sonarr:8989`)
- Perfil de idioma: **Português** (`pob` + `por`)
- Providers: OpenSubtitles.com, LegendasDivx, LegendasNET
- Acesse: `bazarr.oci.clsmfm.space`

### qBittorrent
- Web UI na porta `8082` (evita conflito com 8080)
- Credenciais definidas no `.env`

### Plex
- `network_mode: host` para descoberta na rede local
- Bibliotecas: TV (`/tv`), Movies (`/movies`)

### Jellyfin
- Alternativa open-source ao Plex
- Biblioteca Movies configurada em `/data/movies`
- Porta `8096` — adequado para streaming remoto sem assinatura Plex

---

## Como baixar conteúdo

### Filme (Radarr)
1. Abrir Radarr → **Add New**
2. Pesquisar o filme → selecionar
3. Root Folder: **`/movies`** (selecionar no dropdown)
4. Quality Profile: ex. HD-1080p
5. **Marque "Start search for missing movie"** (Radarr não tem isso global)
6. **Add Movie** → acompanhar no qBittorrent e em Radarr → Activity
7. Se esqueceu a opção acima, rode `make search-missing`

### Série (Sonarr)
1. Abrir Sonarr → **Add New**
2. Pesquisar a série → selecionar
3. Root Folder: **`/tv`**
4. Monitor: All Episodes (ou conforme preferência)
5. **Marque "Start search for missing episodes"** (Sonarr não tem isso global)
6. **Add Series** → ou rode `make search-missing` depois

### Seerr (requisições)
- Ao pedir um filme/série, escolha **"Request and Search"** em vez de apenas "Request".
- Se pediu apenas "Request", rode `make search-missing` para buscar.

### Assistir
- **Plex**: `http://<servidor>:32400/web`
- **Jellyfin**: `http://<servidor>:8096`

---

## Legendas (Bazarr)

O **Bazarr** é configurado automaticamente pelo `make configure` para:

- Sincronizar filmes do **Radarr** e séries do **Sonarr**
- Baixar legendas em **Português (Brasil)** e **Português**
- Usar os providers: **OpenSubtitles.com**, **LegendasDivx** e **LegendasNET**
- Autenticação com as mesmas credenciais do `.env` (`COMMON_USER` / `COMMON_PASSWORD`)

O download de legendas acontece **após** o Radarr/Sonarr importarem o arquivo para `/media/movies` ou `/media/tv`. Você pode acompanhar em:

- **Bazarr**: `bazarr.oci.clsmfm.space`
- Seção **Wanted** → filmes/séries sem legenda

Se precisar reconfigurar só o Bazarr:

```bash
make configure-bazarr
```

---

## Acesso remoto

### SSH tunnel (recomendado para testes)

No computador local:

```bash
ssh -L 8989:localhost:8989 \
    -L 7878:localhost:7878 \
    -L 8082:localhost:8082 \
    -L 9696:localhost:9696 \
    -L 32400:localhost:32400 \
    -L 8096:localhost:8096 \
    ubuntu@<IP_DA_VM>
```

Depois aceder via `http://localhost:<porta>`.

### Acesso direto

Abrir portas no `iptables` da VM e no **Oracle Cloud Security List** (Ingress Rules).

---

## Troubleshooting

| Problema | Solução |
|----------|---------|
| `Connection refused (localhost:7878)` no Prowlarr | Usar `http://radarr:7878` em vez de localhost |
| `'Root Folder Path' must not be empty` | Selecionar `/movies` ou `/tv` no **dropdown**, não escrever à mão |
| Sem indexadores no Radarr/Sonarr | Verificar Prowlarr → Apps → Test → Save; adicionar indexadores no Prowlarr |
| Torrent no qBittorrent mas não importa | Confirmar host `qbittorrent` e pasta `/downloads` partilhada |
| Indexador com erro 522 | Indexador instável — adicionar alternativa (1337x, YTS) no Prowlarr |
| Serviços inacessíveis externamente | Firewall Oracle Cloud + iptables da VM |
| Filme/série adicionado(a) mas não baixa | Marque "Start search for missing..." ao adicionar, use "Request and Search" no Seerr, ou rode `make search-missing` |

### Reaplicar configuração automatizada

```bash
make configure
```

---

## Ficheiros versionados vs. locais

| Versionado (git) | Local apenas (gitignored) |
|------------------|---------------------------|
| `docker-compose.yml` | `.env` |
| `.env.example` | `*/config/` (dados dos serviços) |
| `scripts/arr-stack.json` | `downloads/`, `media/` |
| `scripts/` | API keys geradas pelos serviços |
| `Makefile`, `README.md` | |
| `scripts/` | |

---

## Referências

- [Plex Claim](https://www.plex.tv/claim)
- [Servarr Wiki](https://wiki.servarr.com/)
- [LinuxServer.io Images](https://docs.linuxserver.io/)

---

## Seerr

Seerr é o gerenciador de requisições de mídia para filmes e séries. Ele está disponível em:

- Local: `http://localhost:5055`
- Na rede/externo: `http://<ip-ou-dominio-publico>:5055` ou uma URL HTTPS via reverse proxy/tunnel

### Acesso externo e Pocket for Seerr

O Pocket for Seerr no iOS conecta diretamente na URL pública do Seerr. Depois de criar o admin, o app precisa apenas da URL pública e das credenciais desse admin.

Opções comuns para URL pública:

- Liberar a porta `5055` no firewall/roteador/cloud e usar `http://<ip-publico>:5055`.
- Usar reverse proxy com HTTPS, por exemplo `https://seerr.seudominio.com`.
- Usar Cloudflare Tunnel, expondo `http://seerr:5055` internamente para uma URL pública HTTPS.
- Usar Tailscale se o acesso for privado entre dispositivos autorizados.

No Seerr, configurar a URL pública em **Settings** -> **General** -> **Application URL** / URL base pública, usando a mesma URL que será colocada no Pocket for Seerr.

A configuração do Seerr é feita automaticamente por `make configure` (script `scripts/configure.sh`), que conecta Jellyfin, Radarr e Sonarr usando as URLs internas Docker.
