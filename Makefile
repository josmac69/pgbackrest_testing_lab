.PHONY: help build clean lab1-up lab1-down lab2-up lab2-down lab3-up lab3-down lab4-up lab4-down test-all

help:
	@echo "pgBackRest Testing Lab Orchestrator"
	@echo "=================================="
	@echo "Available commands:"
	@echo "  make build       - Build the unified base Docker image"
	@echo "  make clean       - Clean up all containers, volumes, and networks across all labs"
	@echo ""
	@echo "Lab 1 (Basic SSH Repo):"
	@echo "  make lab1-up     - Start Lab 1"
	@echo "  make lab1-down   - Stop Lab 1"
	@echo ""
	@echo "Lab 2 (S3 MinIO PITR):"
	@echo "  make lab2-up     - Start Lab 2"
	@echo "  make lab2-down   - Stop Lab 2"
	@echo ""
	@echo "Lab 3 (Backup from Standby):"
	@echo "  make lab3-up     - Start Lab 3"
	@echo "  make lab3-down   - Stop Lab 3"
	@echo ""
	@echo "Lab 4 (Troubleshooting):"
	@echo "  make lab4-up     - Start Lab 4"
	@echo "  make lab4-down   - Stop Lab 4"
	@echo ""
	@echo "Validation:"
	@echo "  make test-all    - Run automated end-to-end tests for all labs"

build:
	docker build -t pgbackrest-lab-base .

clean:
	@echo "Cleaning up all docker environments..."
	@cd 01-basic-ssh-repo && docker compose down -v --remove-orphans || true
	@cd 02-s3-minio-pitr && docker compose down -v --remove-orphans || true
	@cd 03-backup-from-standby && docker compose down -v --remove-orphans || true
	@cd 04-troubleshooting && docker compose down -v --remove-orphans || true
	@docker network prune -f || true
	@docker volume prune -f || true

lab1-up: build
	@cd 01-basic-ssh-repo && docker compose up -d

lab1-down:
	@cd 01-basic-ssh-repo && docker compose down -v

lab2-up: build
	@cd 02-s3-minio-pitr && docker compose up -d

lab2-down:
	@cd 02-s3-minio-pitr && docker compose down -v

lab3-up: build
	@cd 03-backup-from-standby && docker compose up -d

lab3-down:
	@cd 03-backup-from-standby && docker compose down -v

lab4-up: build
	@cd 04-troubleshooting && docker compose up -d

lab4-down:
	@cd 04-troubleshooting && docker compose down -v

test-all: build
	@echo "Starting automated end-to-end verification for all labs..."
	@echo "========================================================="
	@echo "Testing Lab 1..."
	@cd 01-basic-ssh-repo && $(MAKE) test
	@echo "Testing Lab 2..."
	@cd 02-s3-minio-pitr && $(MAKE) test
	@echo "Testing Lab 3..."
	@cd 03-backup-from-standby && $(MAKE) test
	@echo "Testing Lab 4..."
	@cd 04-troubleshooting && $(MAKE) test
	@echo "========================================================="
	@echo "All labs verified successfully!"
