.PHONY: help up down status stanza-create check backup info stop-db start-db restore-pitr test

help:
	@echo "Lab 2: S3-Compatible Storage & PITR"
	@echo "==================================="
	@echo "Commands:"
	@echo "  make up            - Spin up pg-primary and MinIO containers"
	@echo "  make down          - Destroy containers and delete volumes"
	@echo "  make status        - Check container status and database readiness"
	@echo "  make stanza-create - Create the pgBackRest stanza on S3 (MinIO)"
	@echo "  make check         - Validate the stanza S3 configuration"
	@echo "  make backup        - Run a Full backup directly to S3"
	@echo "  make info          - Show stanza backups info from S3"
	@echo "  make stop-db       - Stop PostgreSQL on the primary node"
	@echo "  make start-db      - Start PostgreSQL on the primary node"
	@echo "  make restore-pitr  - Run PITR. Requires TARGET_TIME parameter."
	@echo "                       Example: make restore-pitr TARGET_TIME=\"2026-07-10 12:00:00\""
	@echo "  make test          - Run the end-to-end automated test script"

up:
	@if [ ! -f certs/private.key ]; then \
		echo "Generating self-signed TLS certificates for MinIO..."; \
		mkdir -p certs; \
		openssl req -new -x509 -nodes -days 365 \
			-keyout certs/private.key \
			-out certs/public.crt \
			-subj "/CN=minio" \
			-addext "subjectAltName=DNS:minio,DNS:localhost,IP:127.0.0.1"; \
		chmod 644 certs/private.key certs/public.crt; \
	fi
	docker compose up -d

down:
	docker compose down -v
	rm -rf certs

status:
	@docker ps -f name=pg-primary-s3 -f name=minio
	@echo "PostgreSQL primary readiness:"
	@docker exec -u postgres pg-primary-s3 pg_isready || echo "PG is stopped or starting"

stanza-create:
	docker exec -u postgres pg-primary-s3 pgbackrest --stanza=demo stanza-create

check:
	docker exec -u postgres pg-primary-s3 pgbackrest --stanza=demo check

backup:
	docker exec -u postgres pg-primary-s3 pgbackrest --stanza=demo --type=full backup

info:
	docker exec -u postgres pg-primary-s3 pgbackrest --stanza=demo info

stop-db:
	docker exec -u postgres pg-primary-s3 /usr/lib/postgresql/16/bin/pg_ctl -D /var/lib/postgresql/16/main -m fast stop

start-db:
	docker exec -u postgres pg-primary-s3 /usr/lib/postgresql/16/bin/pg_ctl -D /var/lib/postgresql/16/main -l /var/lib/postgresql/postgresql.log start

restore-pitr:
	@if [ -z "$(TARGET_TIME)" ]; then \
		echo "Error: TARGET_TIME parameter is required."; \
		echo "Usage: make restore-pitr TARGET_TIME=\"YYYY-MM-DD HH:MM:SS\""; \
		exit 1; \
	fi
	@echo "Stopping PostgreSQL..."
	docker exec -u postgres pg-primary-s3 /usr/lib/postgresql/16/bin/pg_ctl -D /var/lib/postgresql/16/main -m fast stop || true
	@echo "Wiping data directory..."
	docker exec -u postgres pg-primary-s3 bash -c "rm -rf /var/lib/postgresql/16/main/*"
	@echo "Running pgBackRest PITR restore to $(TARGET_TIME)..."
	docker exec -u postgres pg-primary-s3 pgbackrest --stanza=demo --type=time --target="$(TARGET_TIME)" --target-action=promote restore
	@echo "Starting PostgreSQL in recovery mode..."
	docker exec -u postgres pg-primary-s3 /usr/lib/postgresql/16/bin/pg_ctl -D /var/lib/postgresql/16/main -l /var/lib/postgresql/postgresql.log start
	@echo "Restore initiated. Monitor logs using docker logs pg-primary-s3."

test:
	@chmod +x test.sh
	./test.sh
