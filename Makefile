.PHONY: help setup up configure validate smoke-test e2e-test logs ps down

help:
	@echo "Comandos disponíveis:"
	@echo "  make setup      - Cria estrutura de pastas e .env a partir do .env.example"
	@echo "  make up         - Sobe todos os containers com docker compose up -d"
	@echo "  make configure  - Configura *Arr, qBittorrent, Jellyfin (via Seerr) e Seerr"
	@echo "  make validate   - Valida dependências, variáveis, scripts e Docker Compose"
	@echo "  make smoke-test - Verifica containers e endpoints HTTP/API com a stack ativa"
	@echo "  make e2e-test   - Valida o fluxo principal em modo dry-run por padrão"
	@echo "  make logs       - Mostra logs recentes da stack"
	@echo "  make ps         - Mostra o estado dos containers"
	@echo "  make down       - Derruba todos os containers"
	@echo "  make help       - Mostra esta ajuda"

setup:
	./scripts/setup.sh

up:
	docker compose up -d

configure:
	./scripts/configure.sh

validate:
	./scripts/validate.sh

smoke-test:
	./scripts/smoke-test.sh

e2e-test:
	@DRY_RUN="$(DRY_RUN)" MOVIE_TMDB_ID="$(MOVIE_TMDB_ID)" MOVIE_TITLE="$(MOVIE_TITLE)" ./scripts/e2e-test.sh

logs:
	docker compose logs --tail=200

ps:
	docker compose ps

down:
	docker compose down
