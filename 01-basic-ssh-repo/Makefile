.PHONY: help up down status stanza-create check backup-full backup-incr info corrupt restore start-db stop-db test

help:
	@echo "Lab 1: Basic SSH Repository Setup"
	@echo "================================="
	@echo "Commands:"
	@echo "  make up            - Spin up primary and repository containers"
	@echo "  make down          - Destroy containers and delete volumes"
	@echo "  make status        - Check container status and PostgreSQL readiness"
	@echo "  make stanza-create - Create the pgBackRest stanza on the repo host"
	@echo "  make check         - Validate the stanza configuration"
	@echo "  make backup-full   - Trigger a Full backup from the repository"
	@echo "  make backup-incr   - Trigger an Incremental backup from the repository"
	@echo "  make info          - Show stanza backups info"
	@echo "  make stop-db       - Stop PostgreSQL on the primary node"
	@echo "  make start-db      - Start PostgreSQL on the primary node"
	@echo "  make corrupt       - Force-wipe the database data directory (simulates corruption)"
	@echo "  make restore       - Perform restore using pgBackRest (database must be stopped)"
	@echo "  make test          - Run the end-to-end automated test script"

up:
	docker compose up -d

down:
	docker compose down -v

status:
	@docker ps -f name=pg-primary -f name=pgbackrest-repo
	@echo "PostgreSQL primary readiness:"
	@docker exec -u postgres pg-primary pg_isready || echo "PG is stopped or starting"

stanza-create:
	docker exec -u postgres pgbackrest-repo pgbackrest --stanza=demo stanza-create

check:
	docker exec -u postgres pgbackrest-repo pgbackrest --stanza=demo check

backup-full:
	docker exec -u postgres pgbackrest-repo pgbackrest --stanza=demo --type=full backup

backup-incr:
	docker exec -u postgres pgbackrest-repo pgbackrest --stanza=demo --type=incr backup

info:
	docker exec -u postgres pgbackrest-repo pgbackrest --stanza=demo info

stop-db:
	docker exec -u postgres pg-primary /usr/lib/postgresql/16/bin/pg_ctl -D /var/lib/postgresql/16/main -m immediate stop

start-db:
	docker exec -u postgres pg-primary /usr/lib/postgresql/16/bin/pg_ctl -D /var/lib/postgresql/16/main -l /var/lib/postgresql/postgresql.log start

corrupt: stop-db
	@echo "Wiping database data files..."
	docker exec -u postgres pg-primary bash -c "rm -rf /var/lib/postgresql/16/main/*"
	@echo "Data folder wiped. DB is stopped. Ready for restore."

restore:
	docker exec -u postgres pg-primary pgbackrest --stanza=demo restore

test:
	@chmod +x test.sh
	./test.sh
