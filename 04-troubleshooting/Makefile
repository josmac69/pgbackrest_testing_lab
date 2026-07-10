.PHONY: help up down status stanza-create check backup break-scenario1 break-scenario2 break-scenario3 test

help:
	@echo "Lab 4: Troubleshooting pgBackRest Failures"
	@echo "========================================="
	@echo "Lifecycle commands:"
	@echo "  make up              - Spin up PG and Repository containers"
	@echo "  make down            - Destroy containers and delete volumes"
	@echo "  make status          - Check container status and database readiness"
	@echo "  make stanza-create   - Create the pgBackRest stanza"
	@echo "  make check           - Validate the stanza configuration"
	@echo "  make backup          - Run a baseline Full backup"
	@echo ""
	@echo "Troubleshooting exercises (Trigger failure):"
	@echo "  make break-scenario1 - Trigger Scenario 1: System Identifier Mismatch"
	@echo "  make break-scenario2 - Trigger Scenario 2: Locked Repository"
	@echo "  make break-scenario3 - Trigger Scenario 3: SSH Connection Denied"
	@echo ""
	@echo "Validation:"
	@echo "  make test            - Run the automated troubleshooting test suite"

up:
	docker compose up -d

down:
	docker compose down -v

status:
	@docker ps -f name=pg-primary-debug -f name=pgbackrest-repo-debug
	@echo "PostgreSQL primary readiness:"
	@docker exec -u postgres pg-primary-debug pg_isready || echo "PG is stopped or starting"

stanza-create:
	docker exec -u postgres pgbackrest-repo-debug pgbackrest --stanza=demo stanza-create

check:
	docker exec -u postgres pgbackrest-repo-debug pgbackrest --stanza=demo check

backup:
	docker exec -u postgres pgbackrest-repo-debug pgbackrest --stanza=demo --type=full backup

break-scenario1:
	@chmod +x scenarios/break-stanza-mismatch.sh
	./scenarios/break-stanza-mismatch.sh

break-scenario2:
	@chmod +x scenarios/break-repo-locked.sh
	./scenarios/break-repo-locked.sh

break-scenario3:
	@chmod +x scenarios/break-ssh-denied.sh
	./scenarios/break-ssh-denied.sh

test:
	@chmod +x test.sh
	./test.sh
