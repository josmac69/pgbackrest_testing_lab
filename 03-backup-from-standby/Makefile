.PHONY: help up down status stanza-create check backup info stop-standby bootstrap-standby start-standby test

help:
	@echo "Lab 3: Backup Offloading to Standby"
	@echo "==================================="
	@echo "Commands:"
	@echo "  make up                - Spin up primary, standby, and repository containers"
	@echo "  make down              - Destroy containers and delete volumes"
	@echo "  make status            - Check replication status and node readiness"
	@echo "  make stanza-create     - Create the pgBackRest stanza on the repo host"
	@echo "  make check             - Validate the stanza configuration"
	@echo "  make backup            - Trigger a Full backup (will copy from standby)"
	@echo "  make info              - Show stanza backups info"
	@echo "  make stop-standby      - Stop PostgreSQL on the standby node"
	@echo "  make start-standby     - Start PostgreSQL on the standby node"
	@echo "  make bootstrap-standby - Rebuild a completely wiped standby using pgBackRest"
	@echo "  make test              - Run the end-to-end automated test script"

up:
	docker compose up -d

down:
	docker compose down -v

status:
	@docker ps -f name=pg-primary-replic -f name=pg-standby-replic -f name=pgbackrest-repo-replic
	@echo "--- Replication Status ---"
	@docker exec -u postgres pg-primary-replic psql -c "SELECT application_name, client_addr, state, sync_state FROM pg_stat_replication;" || echo "Primary is offline"
	@echo "--- Standby Status ---"
	@docker exec -u postgres pg-standby-replic pg_isready || echo "Standby is offline"

stanza-create:
	docker exec -u postgres pgbackrest-repo-replic pgbackrest --stanza=demo stanza-create

check:
	docker exec -u postgres pgbackrest-repo-replic pgbackrest --stanza=demo check

backup:
	docker exec -u postgres pgbackrest-repo-replic pgbackrest --stanza=demo --type=full backup

info:
	docker exec -u postgres pgbackrest-repo-replic pgbackrest --stanza=demo info

stop-standby:
	docker exec -u postgres pg-standby-replic /usr/lib/postgresql/16/bin/pg_ctl -D /var/lib/postgresql/16/main -m immediate stop

start-standby:
	docker exec -u postgres pg-standby-replic /usr/lib/postgresql/16/bin/pg_ctl -D /var/lib/postgresql/16/main -l /var/lib/postgresql/postgresql.log start

bootstrap-standby: stop-standby
	@echo "Wiping standby database files..."
	docker exec -u postgres pg-standby-replic bash -c "rm -rf /var/lib/postgresql/16/main/*"
	@echo "Restoring standby files using pgBackRest..."
	docker exec -u postgres pg-standby-replic pgbackrest --stanza=demo --type=standby restore
	@echo "Writing primary_conninfo to standby configuration..."
	docker exec -u postgres pg-standby-replic bash -c "echo \"primary_conninfo = 'host=pg-primary-replic port=5432 user=replication_user password=replica_password'\" >> /var/lib/postgresql/16/main/postgresql.auto.conf"
	@echo "Starting standby database..."
	docker exec -u postgres pg-standby-replic /usr/lib/postgresql/16/bin/pg_ctl -D /var/lib/postgresql/16/main -l /var/lib/postgresql/postgresql.log start
	@echo "Standby bootstrapped and started. Monitor replication status using make status."

test:
	@chmod +x test.sh
	./test.sh
