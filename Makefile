.PHONY: help up setup configure down

help:
	@echo "Comandos disponíveis:"
	@echo "  make setup      - Cria estrutura de pastas e .env a partir do .env.example"
	@echo "  make up         - Sobe todos os containers com docker compose up -d"
	@echo "  make configure  - Configura *Arr, qBittorrent, Jellyfin (via Seerr) e Seerr"
	@echo "  make down       - Derruba todos os containers"
	@echo "  make help       - Mostra esta ajuda"

up:
	docker compose up -d

setup:
	./scripts/setup.sh

configure:
	./scripts/configure.sh

down:
	docker compose down
