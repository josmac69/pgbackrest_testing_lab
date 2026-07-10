# pgBackRest Hands-On Teaching Lab

Welcome to the **pgBackRest Educational Testing Lab**! This repository contains a suite of self-contained, Docker-based testing environments designed for database administrators and students to learn the fundamentals, advanced patterns, and troubleshooting of **pgBackRest** (the enterprise-grade PostgreSQL backup and restore utility).

---

## 🏗️ Architecture & Lab Overview

All labs share a common, highly optimized base Docker image containing **PostgreSQL 16** and **pgBackRest**. Each lab spins up its own localized network, enabling students to explore specific architectures in isolation.

The workshop is organized into four separate laboratories:

```
pgbackrest_testing_lab/
├── 01-basic-ssh-repo/         # Lab 1: Dedicated pgBackRest repository server via SSH
├── 02-s3-minio-pitr/          # Lab 2: Direct-to-S3 backup using MinIO & Point-in-Time Recovery
├── 03-backup-from-standby/    # Lab 3: Multi-node replication cluster & offloading backups to a replica
└── 04-troubleshooting/        # Lab 4: Interactive troubleshooting scenarios (Fix-it lab)
```

### 🧪 The Labs

| Lab Directory | Topic | Key Learnings |
| :--- | :--- | :--- |
| **`01-basic-ssh-repo`** | Basic Backup & Restore | Configuring SSH keys between DB & Repo, stanza creation, checking configurations, running full/incremental backups, and restoring after complete database loss. |
| **`02-s3-minio-pitr`** | S3 Backups & PITR | Storing backups in S3-compatible storage (MinIO), timeline management, and executing Point-in-Time Recovery (PITR) to restore deleted tables. |
| **`03-backup-from-standby`** | Offloading to Standby | Streaming replication setup, configuring pgBackRest standby backup offloading (`backup-standby=y`), and bootstrapping replicas from backup. |
| **`04-troubleshooting`** | Failure & Debugging | Diagnosing and fixing: System ID mismatches, locked repositories, permission issues, and PostgreSQL major version upgrades. |

---

## 🛠️ Prerequisites

To run these labs, ensure the following are installed on your host system:
- **Docker** (version 20.10+)
- **Docker Compose** (V2+, using `docker compose` syntax)
- **Make**

---

## 🚀 Quick Start

1. **Build the Shared Base Image** (this builds the PostgreSQL + pgBackRest environment once, making container initialization instant):
   ```bash
   make build
   ```

2. **Run a Lab**:
   Navigate to a lab directory and use its local `Makefile`, or run from the root:
   ```bash
   # Start Lab 1
   make lab1-up
   
   # Stop and Clean Lab 1
   make lab1-down
   ```

3. **Run Automated Tests**:
   Verify that all configurations, backups, and restores compile and execute successfully across all labs:
   ```bash
   make test-all
   ```

4. **Wipe All Environments**:
   To clean up all containers, volumes, and prune docker networks:
   ```bash
   make clean
   ```

---

## 📖 How to Teach / Learn

Each directory contains a dedicated, rich **`README.md`** that serves as a student lab guide. 
Each lab guide includes:
- **Architecture Diagram**: Explaining how the components connect.
- **Configuration Walkthrough**: Detailing the `pgbackrest.conf` parameters.
- **Hands-on Exercise**: Step-by-step commands to run, observe, and inspect.
- **Key Takeaways**: Explanations of what is happening under the hood.

We recommend going through the labs sequentially from **Lab 1** to **Lab 4**.