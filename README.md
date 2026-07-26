# CLSS Streaming

Stack local de mídia com Seerr, Radarr, Prowlarr, qBittorrent, Bazarr, Jellyfin e Plex.

Fluxo principal esperado:

```text
pedido no Seerr
-> filme no Radarr
-> busca via Prowlarr/indexers
-> download no qBittorrent
-> importação pelo Radarr
-> legenda pelo Bazarr
-> biblioteca acessível no Jellyfin/Plex
```

## Fluxo Oficial

Depois de preencher o `.env`, use exatamente:

```bash
make setup
make up
make configure
```

`make up` apenas sobe os containers. Ele não executa `make configure`.

## Comandos

```bash
make setup       # cria diretórios, .env quando ausente, permissões e valida pré-requisitos
make up          # docker compose up -d
make configure   # aplica a configuração pós-deploy idempotente
make validate    # valida dependências, .env, scripts, Compose, volumes e segredos óbvios
make smoke-test  # verifica containers e endpoints HTTP/API
make e2e-test    # valida integrações em dry-run por padrão
make logs        # logs recentes da stack
make ps          # estado dos containers
make down        # docker compose down
```

## Serviços

| Serviço | Porta padrão | Função |
| --- | ---: | --- |
| Seerr | 5055 | Solicitações de mídia |
| Radarr | 7878 | Filmes |
| Prowlarr | 9696 | Indexers e sync para Radarr |
| qBittorrent | 8082 | Cliente de download |
| Bazarr | 6767 | Legendas |
| Jellyfin | 8096 | Streaming |
| Plex | 32400 | Streaming |
| Sonarr | 8989 | Séries, mantido na stack |

As portas principais são configuráveis em `.env`.

## Volumes

Modelo de paths usado pela stack:

| Path no container | Serviços | Path no host |
| --- | --- | --- |
| `/downloads` | qBittorrent, Radarr, Sonarr | `./media/downloads` |
| `/movies` | Radarr, Plex | `./media/movies` |
| `/tv` | Sonarr, Plex | `./media/tv` |
| `/data/movies` | Jellyfin | `./media/movies` |
| `/data/tvshows` | Jellyfin | `./media/tv` |

O qBittorrent salva em `/downloads`; o Radarr importa de `/downloads` para `/movies`; Jellyfin e Plex leem a biblioteca final.

## Variáveis

Crie o `.env` com `make setup` ou copie `.env.example` manualmente. Preencha pelo menos:

```text
PUID
PGID
TZ
COMMON_USER
COMMON_PASSWORD
QBITTORRENT_USER
QBITTORRENT_PASSWORD
AMIGOS_SHARE_USERNAME
AMIGOS_SHARE_PASSWORD
WEBUI_PORT
RADARR_PORT
PROWLARR_PORT
BAZARR_PORT
SEERR_PORT
JELLYFIN_PORT
SEERR_ADMIN_EMAIL
SEERR_ADMIN_PASSWORD
JELLYFIN_ADMIN_USER
JELLYFIN_ADMIN_PASSWORD
```

`PLEX_CLAIM` é externo e opcional para a automação do repositório, mas normalmente é necessário para o primeiro claim do Plex. Gere em `https://www.plex.tv/claim`; o token expira em poucos minutos.

## Configuração Automática

`make configure` executa `scripts/configure.sh` e tenta corrigir estados parciais sem duplicar recursos:

- qBittorrent usa usuário e senha do `.env`;
- qBittorrent é configurado no Radarr com host interno `qbittorrent` e categoria `movies-radarr`;
- Radarr recebe root folder `/movies`;
- Prowlarr recebe Application do Radarr com `http://radarr:7878`;
- indexers automáticos são tentados no Prowlarr quando o schema está disponível;
- sync de indexers Prowlarr -> Radarr é disparado;
- Bazarr é conectado ao Radarr e recebe perfil de legenda em português/pt-BR;
- Seerr é conectado ao Radarr usando root folder e quality profile válidos;
- Jellyfin é configurado no Seerr quando a API permite.

Falhas de indexers ou providers que exigem login, convite, conta, região suportada ou captcha são tratadas como dependência externa/manual.

## Validação

Validação estática:

```bash
make validate
```

Com a stack ativa:

```bash
make smoke-test
make e2e-test DRY_RUN=true
```

Parâmetros do e2e:

```bash
make e2e-test DRY_RUN=true MOVIE_TMDB_ID=550 MOVIE_TITLE="Fight Club"
```

Valores de `make` têm precedência sobre `E2E_MOVIE_TMDB_ID`, `E2E_MOVIE_TITLE` e `E2E_DRY_RUN` no `.env`.

Em `DRY_RUN=true`, o script não inicia download real. Ele valida conexões, root folders, download client, paths de containers, Prowlarr, Seerr, Bazarr, qBittorrent, Jellyfin e Plex. Ausência de indexer ativo ou ausência de release específico é reportada separadamente de falha de infraestrutura.

`DRY_RUN=false` só deve ser usado com conteúdo legal, próprio, livre ou expressamente autorizado e com `E2E_AUTHORIZED_CONTENT=true`.

## Operação

Para pedir um filme, use o Seerr e escolha a opção que solicita e pesquisa. O pedido deve aparecer no Radarr, que usa indexers sincronizados pelo Prowlarr e envia downloads ao qBittorrent.

No Plex, o claim do servidor e a criação/scan de bibliotecas podem exigir interação manual. Use `/movies` para filmes e `/tv` para séries.

No Jellyfin, confirme que a biblioteca de filmes aponta para `/data/movies` e a de séries para `/data/tvshows`.

## Troubleshooting

`config.xml` do qBittorrent ainda não gerado:
aguarde o primeiro start do container e rode `make configure` novamente.

Senha temporária do qBittorrent:
o script lê a senha temporária dos logs quando precisa trocar para a senha do `.env`. Se os logs não tiverem mais a senha, ajuste pela Web UI e rode `make configure`.

Rede `traefik-public` ausente:
o Compose usa essa rede externa. Crie a rede ou ajuste o Compose antes de `make up`.

Portas em conflito:
altere as portas no `.env` e rode `make up` novamente.

Bazarr ainda inicializando:
aguarde `config.yaml` e `bazarr.db` existirem em `bazarr/config/` e rode `make configure`.

Prowlarr sem indexer disponível:
adicione um indexer manualmente no Prowlarr quando houver exigência de login, convite, captcha ou bloqueio regional. Depois rode `make configure` para sincronizar.

Radarr sem importar:
confirme que qBittorrent, Radarr e Sonarr veem o mesmo path `/downloads`, e que Radarr tem `/movies` como root folder.

Seerr cria solicitação sem buscar:
use a opção de solicitar e pesquisar. Sem essa ação, a solicitação pode chegar ao Radarr sem iniciar busca.

qBittorrent conclui download sem importação:
verifique categoria `movies-radarr`, path `/downloads`, atividade do Radarr e permissões em `./media`.

Plex:
`PLEX_CLAIM` pode estar ausente ou expirado. Claim e bibliotecas podem exigir ação manual pela UI do Plex.

Providers de legenda:
OpenSubtitles e outros providers podem exigir conta ou login manual no Bazarr.

Execução parcial de `make configure`:
corrija a causa indicada no erro e rode `make configure` novamente. O script atualiza recursos existentes em vez de criar duplicatas.

## Arquivos

Arquivos versionados principais:

```text
Makefile
docker-compose.yml
.env.example
scripts/setup.sh
scripts/configure.sh
scripts/validate.sh
scripts/smoke-test.sh
scripts/e2e-test.sh
scripts/arr-stack.json
README.md
```

Dados locais e segredos ficam fora do git, incluindo `.env`, configs dos serviços, bancos, downloads e mídia.
