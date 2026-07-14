# pgBackRest: A Source-Level Technical Deep Dive

*Advanced technical documentation for PostgreSQL specialists. Reflects pgBackRest v2.58.0 and repository state as of July 2026.*

## Table of Contents
1. Status & Executive Summary (TL;DR)
2. Key Findings
3. Command/Action Inventory
4. Architecture Deep Dive
5. Backup & Restore Execution Flow (source-level)
6. Block Incremental, Bundling, Compression, Encryption, Checksums
7. Configuration, Deployment Topologies, PostgreSQL Interaction
8. History & Design Decisions
9. Gaps, Weaknesses, Critique
10. Operational/Feature Comparison
11. Recommendations
12. Caveats

---

## 1. TL;DR

- **pgBackRest is a pure-C, single-binary physical backup/restore tool whose architecture — a declarative config-driven command dispatcher layered over a PostgreSQL-style memory-context object model, a streaming IO-filter pipeline, a pluggable storage-driver abstraction, and a custom local/remote/async protocol — is the most sophisticated of any open-source PostgreSQL backup tool, and at v2.58.0 it remains best-in-class for large clusters.**
- **It nearly died and came back:** sole maintainer David Steele archived the repo (read-only) on April 27, 2026 after Crunchy Data's acquisition removed his funding; a multi-sponsor coalition (AWS, Supabase, pgEdge, Tiger Data, Percona, Eon) revived active development on May 18, 2026, and the project is maintained again.
- **Its real weaknesses are structural, not functional:** process-based (not thread-based) parallelism, DELTA-style block-incremental that still reads all data (no PTRACK), tight one-stanza-per-cluster coupling, repository-format lock-in, no native Kubernetes operator, and a verbose custom C object system that narrows the contributor pool.

---

## 2. Key Findings

- Current stable release: **v2.58.0**, released **January 19, 2026** (confirmed via postgresql.org release announcement; that release also made TLS ≥ 1.2 mandatory and dynamically sized S3/GCS/Azure upload chunks). REPOSITORY_FORMAT = 5 (`src/version.h`). License: **MIT**. Supports 10 PostgreSQL versions (5 supported + 5 EOL), currently through PG18.
- The entire tool is one statically-linked C binary; `src/main.c` bootstraps and dispatches 23 declaratively-defined commands. No Perl runs at runtime (Perl survives only for the docs build and test orchestration).
- Block incremental (v2.46) uses **xxHash** block checksums and variable block sizes (8–88 KiB); file bundling (v2.39) collapses small files for object stores; both are backward-incompatible with older pgBackRest.
- The 2026 maintenance crisis and coalition revival are the single most important operational fact for anyone making a tooling decision today.

---

## 3. Command/Action Inventory

`pgbackrest` is a single statically-linked C executable. `src/main.c` runs `main()`, which bootstraps and dispatches one command. Startup order: `errorHandlerSet()` (registers `stackTraceClean` + `memContextClean` as exception handlers), `storageHelperInit()` (registers driver factories for posix/azure/cifs/gcs/s3/sftp), `cmdInit()`, `statInit()`, `exitInit()`, `cfgLoad()` (parse args/config, apply defaults + validation, init logging), then dispatch by switching on `cfgCommand()` and `cfgCommandRole()`.

Commands are defined declaratively in `src/build/config/config.yaml` (~190+ options across 23 commands). Complete set (from `pgbackrest help`):

| Command | Purpose | Key source |
|---|---|---|
| **backup** | Back up a cluster (full/diff/incr) | `src/command/backup/backup.c`, `file.c`, `protocol.c` |
| **restore** | Restore a cluster, PITR, delta restore | `src/command/restore/restore.c`, `file.c`, `protocol.c` |
| **archive-push** | Push a WAL segment (called by PG `archive_command`) | `src/command/archive/push/push.c` |
| **archive-get** | Get a WAL segment (called by PG `restore_command`) | `src/command/archive/get/get.c` |
| **stanza-create** | Initialize repository structures for a cluster | `src/command/stanza/create.c` |
| **stanza-upgrade** | Update info files after a PG version upgrade | `src/command/stanza/upgrade.c` |
| **stanza-delete** | Remove all backups/archives for a stanza | `src/command/stanza/delete.c` |
| **check** | Validate config, archiving, and backup capability | `src/command/check/check.c` |
| **info** | Report on backups (text or JSON) | `src/command/info/info.c` |
| **expire** | Expire backups/WAL exceeding retention | `src/command/expire/expire.c` |
| **verify** | Validate repository contents vs. manifest | `src/command/verify/verify.c` |
| **annotate** | Add/modify/remove key-value annotations on a backup | `src/command/annotate/` |
| **repo-get / repo-ls / repo-put / repo-rm** | Low-level repository file operations | `src/command/repo/` |
| **server / server-ping** | TLS server daemon mode; aliveness ping | `src/command/server/` |
| **start / stop** | Allow / prevent pgBackRest processes (lock-based) | `src/command/control/` |
| **help / version** | Help (from `src/build/help/help.xml` → `help.auto.c.inc`); version | `src/command/help/`, `version.c` |

**Command roles** (chosen by `cfgCommandRole()`): `main` (default), `async` (async archive-push/get), `local` (parallel workers, count = `process-max`), `remote` (protocol server on a remote host). Role-qualified names like `archive-push:async` are parsed by `cfgParseCommandId()`.

Notable semantics:
- **backup**: `--type=full|diff|incr` (default incr, auto-promoted to full if none exists). Waits for required WAL to reach the archive before completing (`archive-timeout`, default 60s). Auto-runs `expire` unless `--no-expire-auto`.
- **restore**: `--delta` (checksum/existing-file reuse), `--type=default|none|immediate|time|xid|lsn|name|standby`, selective DB restore (`--db-include`), tablespace/link remapping. `pg_control` is always restored last so an aborted restore can't start.
- **check**: exercises the full archive round-trip (forces a WAL switch on the primary, confirms the segment lands in each repo).
- **verify**: reads every repo file and validates checksums against the manifest without a restore (introduced v2.39).

---

## 4. Architecture Deep Dive

### 4.1 Source-tree organization (`src/`)
- `src/command/` — one subdirectory per command family (backup, restore, archive/push, archive/get, stanza, check, info, expire, verify, repo, server, control, help).
- `src/common/` — runtime foundation: `memContext.c`; `type/` (String, Buffer, List, KeyValue, Variant, Pack, StringId, `object.h`); `io/` (IoRead/IoWrite, filters, `http/`, `tls/`, `socket/`); `crypto/` (`hash.c` SHA-1, `cipherBlock.c` AES, `xxhash`); `compress/` (gz/lz4/zst/bz2); `error.c`, `log.c`, `fork.c`, `exec.c`, `lock.c`, `ini.c`, `stackTrace.c`.
- `src/config/` — `parse.c` (arg/file/env parsing driven by generated `parse.auto.c.inc`), `load.c`, `config.c` (`cfgOption*` accessors), `config.auto.h`.
- `src/build/` — the **code-generation source of truth**: `build/config/config.yaml` and `build/help/help.xml` generate `parse.auto.c.inc`, `config.auto.h`, and `help.auto.c.inc` at build time.
- `src/db/` — `db.c` PostgreSQL client via protocol (`dbBackupStart`/`dbBackupStop`, `dbReplayWait`).
- `src/info/` — `info.c` (base INI + checksum + copy), `infoPg.c` (cluster identity/history), `infoBackup.c`, `infoArchive.c`, `manifest.c`.
- `src/postgres/` — `interface.c` reads `pg_control` and WAL headers directly (binary, version-adaptive); maps `pg_backup_start`/`pg_backup_stop` across versions.
- `src/protocol/` — `client.c`, `server.c`, `helper.c`, `parallel.c`, `parallelJob.c`.
- `src/storage/` — `storage.c` (`StorageInterface` function table) + drivers `posix/`, `s3/`, `azure/`, `gcs/`, `sftp/`, `cifs/`, `remote/`.

Build system: **meson** (≥0.47, C99). The legacy autoconf/make build was removed after v2.54.x.

### 4.2 Memory-context object model
pgBackRest deliberately re-implements PostgreSQL's memory-context concept in C rather than using C++ or a framework. Every heap allocation belongs to a `MemContext`; contexts form a tree rooted at `contextTop`, with the current context tracked on a `memContextStack` (max depth `MEM_CONTEXT_STACK_MAX` = 128). Key macros (`src/common/memContext.h`):
- `MEM_CONTEXT_NEW_BEGIN` / `MEM_CONTEXT_NEW_END` — create a named child context, switch into it, keep it only if the block completes without error (`memContextKeep()`); on `THROW`, the still-"new" context is auto-freed by `memContextClean()`.
- `MEM_CONTEXT_TEMP_BEGIN` / `MEM_CONTEXT_TEMP_END` — scratch context always freed even on error; `MEM_CONTEXT_TEMP_RESET_BEGIN`/`MEM_CONTEXT_TEMP_RESET(n)` bound peak memory in long loops.
- `MEM_CONTEXT_BEGIN(ctx)` / `MEM_CONTEXT_END()` — switch to an existing context temporarily.

Lifecycle: `memContextSwitch/SwitchBack`, `memContextKeep/Discard`, `memContextMove` (reparent, to hand an object out of a temp context), `memContextFree` (recursive free + single cleanup callback via `memContextCallbackSet`). This integrates with the error system: on `THROW`, `memContextClean(tryDepth, fatal)` frees all "new" contexts at/above the current try depth — exception-safe cleanup without RAII.

**Object pattern** (`src/common/type/object.h`, guidance in CONTRIBUTING.md/CODING.md): objects are opaque — `struct MyObj` is defined only in the `.c` file. Publicly readable fields go in a first-member companion struct `MyObjPub`; inline getters (`FN_INLINE_ALWAYS`) read them via the `THIS_PUB(MyObj)` macro (casts the opaque `this` to its public struct). Construction uses `OBJ_NEW_BEGIN(Type)`/`OBJ_NEW_END`, which wrap `MEM_CONTEXT_NEW_*`: a new MemContext (named after the type for debug audit) is created with an inline `allocExtra` region so the object struct is co-located in the same malloc block as the context header (`memContextAllocExtra()` ↔ `memContextFromAllocExtra()`). `objFree(this)` frees the object's context; `objMove()` reparents it. Result: deterministic bulk cleanup and zero-call inline accessors, at the cost of significant per-object boilerplate.

### 4.3 IO abstraction and filter groups
All byte movement goes through `IoRead`/`IoWrite`. An `IoFilterGroup` is an ordered pipeline of `IoFilter`s applied in-stream during copy: SHA-1 checksum (`cryptoHashNew`, `src/common/crypto/hash.c`, OpenSSL), page-checksum validation (`pageChecksumNew`), block-checksum/block-incremental (`blockChecksumNew`/`blockIncrNew`), compression (gz/lz4/zst/bz2), AES-256-CBC encryption (`cipherBlockNew`, `src/common/crypto/cipherBlock.c`). Because checksum, compression, and encryption occur in one streamed pass, each file is read once — the core of pgBackRest's throughput advantage over tar/rsync-based tools.

### 4.4 Storage driver abstraction
`src/storage/storage.c` defines a `StorageInterface` function table; the concrete driver is selected at runtime from `repo-type` (posix default, plus s3, azure, gcs, sftp, cifs, remote). Cloud drivers (s3/gcs/azure) share the HTTP stack in `src/common/io/http/`, over `src/common/io/tls/` and `src/common/io/socket/`. The `remote` driver forwards storage operations over the protocol. `src/storage/helper.c` factory functions (`storageRepo`, `storagePg`, …) decide local-vs-remote. SFTP (via libssh2, compile-time `HAVE_LIBSSH2`, contributed by Reid Thompson) arrived in v2.46. Cloud chunk sizes are dynamically sized (S3 min part 5MiB; GCS/Azure 4MiB; up to 1GiB) and optimized for small files.

### 4.5 Protocol layer, fork/exec, parallelism
Three distribution patterns: **local** workers (forked children for CPU-bound parallel compression/copy), **remote** processes (SSH or TLS), **async** (background archive processes). `src/protocol/helper.c` builds command lines: `protocolLocalParam()` (local); `protocolRemoteParam()` (remote — SSH: `ssh -o LogLevel=error -o Compression=no -o PasswordAuthentication=no [-p port] user@host command`, or TLS via `TlsClient`). Wire format is a custom binary pack/unpack (`src/common/type/pack.h`). Server handlers registered via `ProtocolServerHandler` structs (`src/protocol/server.h`); storage handlers in `src/storage/remote/protocol.c`.

Parallel job distribution: `ProtocolParallel` (`src/protocol/parallel.c`) + `ProtocolParallelJob` (`parallelJob.c`). `protocolParallelNew(timeout, callbackFn, callbackData)` takes a `ParallelJobCallback` that yields the next job per idle worker; `protocolParallelClientAdd()` registers worker sessions; `protocolParallelProcess()` is the event loop (builds `fd_set`, POSIX `select()`, one outstanding async request per client via `protocolClientSessionRequestAsyncP(.async=true)`); results drained via `protocolParallelResult()`, completion via `protocolParallelDone()`. Worker count = `process-max`. **This is process-based parallelism (fork/exec), not threads.**

**Local/remote versions must match exactly** — a mismatch produces `[ProtocolError] expected value '2.x' for greeting key 'version' but got '2.y'` and blocks archiving/backups.

### 4.6 Config parsing & code generation
`src/config/parse.c` works from two static tables (`parseRuleCommand[]`, `parseRuleOption[]`) compiled from `build/config/config.yaml` into `parse.auto.c.inc`. Rarely-used per-command overrides (allow-range, allow-list, default, required, dependency) are packed into a binary `.pack` field, decoded once per parse. Precedence: **command-line > environment (`PGBACKREST_*`) > config file > default**. `cfgParse()` builds a `Config` on its own MemContext; `cfgInit()` moves it to the top-level context for process lifetime. Options in the wrong section warn (backward compatibility). Env vars: `PGBACKREST_` prefix, uppercased, `-`→`_`; multi-value colon-separated.

### 4.7 Info files & manifest format
All metadata files are INI-format, always written as a primary plus a `.copy` (e.g. `backup.info` + `backup.info.copy`) to survive partial writes; loading tries primary then copy. Each file has a `[backrest]` header and a trailing SHA-1 `backrest-checksum` computed incrementally over each key-value pair in JSON-serialized form (`infoNewLoad`, `src/info/info.c`); a mismatch raises `ChecksumError` (a real-world example: issue #1201, where an encrypted-repo manifest reported "invalid checksum, actual … but expected …"). Sections are written in sorted order (`infoSaveSection`) for deterministic checksums. Encrypted files carry a `[cipher]` section holding a sub-passphrase for dependent files.

Layering: `Info` (base INI/checksum/copy) → `InfoPg` (cluster identity + full version history; archive dir format `<pg-major>-<id>`, e.g. `14-1`) → `InfoBackup` (backup.info) / `InfoArchive` (archive.info). The **manifest** (`src/info/manifest.c`, `backup.manifest`) tracks every file, link, path, ownership (user/group), mode, size, timestamp, and SHA-1; block-incremental fields `blockIncrSize`, `blockIncrChecksumSize`, `blockIncrMapSize` (manifest.h); and page-validation failures. Files are stored in a packed binary `ManifestFilePack` (variable-length integers + bit flags); whole-file checksums stored inline as fixed 20-byte SHA-1. Zero-length files live only in the manifest.

### 4.8 Test framework & docs-as-code
Unit tests target **100% code coverage** (enforced), defined in `test/define.yaml` with test files at `test/src/module/.../*Test.c`, run by a C harness (Perl test build code removed in 2022). Many unit tests and all integration/"real" tests run in Docker containers to simulate multiple hosts, PG versions, and distributions and to use sudo safely; CI runs on GitHub Actions and Cirrus. The **documentation is executable**: `doc/doc.pl` builds docs from XML (`doc/xml/`) by actually running each command inside Docker containers and capturing real output, so documented sequences are validated to work in order. Perl remains only for the doc build (`doc/doc.pl`, `doc/release.pl`, `doc/lib/pgBackRestDoc/`) and test orchestration (`test/test.pl`, `test/lib/`); **no Perl runs at runtime**.

---

## 5. Backup & Restore Execution Flow (source-level)

### 5.1 backup (`src/command/backup/backup.c`)
`cmdBackup()` is the entry point (dispatched from `main.c`); its core worker is `backupProcess()`. Sequence:
1. **`backupInit()`** (~L172–278): connect via `dbGet()` (or read `pg_control` for `--no-online`); retrieve control data (version, system ID, timeline, page size, WAL segment size); validate DB version + system ID against `backup.info`; determine page-checksum applicability.
2. **`backupLabelCreate()`** (~L46–141): generate label `YYYYMMDD-HHMMSSF` / `..._…D` / `..._…I`, handling timestamp collisions.
3. **Manifest build** — `manifestNewBuild()` (`src/info/manifest.c`) scans PGDATA to build the file/link/path/db inventory.
4. **Incremental prep** (diff/incr) — `backupBuildIncrPrior()` (~L544–656) finds a compatible prior backup (validating compression + checksum-page settings match); `backupBuildIncr()` (~L658–695) calls `manifestBuildIncr()` to mark unchanged files as references (no copy), inherits the cipher sub-passphrase from the prior manifest, and sets `backupLabelPrior` to establish the dependency chain.
5. **`pg_backup_start`** — via `dbBackupStart` (`src/db/db.c`); `pgInterfaceBackupStart()` maps to `pg_backup_start()` (PG15+) or non-exclusive `pg_start_backup()` (PG9.6–14). `start-fast=y` forces an immediate checkpoint (otherwise waits for the next scheduled checkpoint).
6. **`backupProcess()`** — dispatches parallel copy jobs via `ProtocolParallel`, adding `process-max` local workers with `protocolLocalGet()`. Each worker runs `backupFileProtocol()` (`src/command/backup/protocol.c`) → `backupFile()`.
7. **`pg_backup_stop`** — via `dbBackupStop`; records stop LSN/WAL; waits for all required WAL to reach the archive (`archive-check`, `archive-timeout`).
8. **`manifestSave()`** — periodically during copy (governed by `manifest-save-threshold`, effective = max(1% of backup size, option value)) to enable efficient resume, then finally at completion; updates `backup.info`.

Typical console trace: `execute non-exclusive backup start: backup begins after the requested immediate checkpoint completes` → `backup start archive = …, lsn = …` → parallel `backup file …` lines → `execute non-exclusive backup stop and wait for all WAL segments to archive` → `new backup label = …` → auto `expire`.

**Per-file copy — `backupFile()` (`src/command/backup/file.c` ~L40–268):** for each file, if `--delta`, checksum the PG file and skip (`backupCopyResultNoOp`) if it matches a referenced prior copy; else decide block-incremental; then copy through the `IoFilterGroup` applying, in order: SHA-1 checksum (`cryptoHashNew`), page-checksum validation (`pageChecksumNew`, relation files only), block-incremental/block-checksum filters, compression, AES encryption. Returns a `BackupFileResult` (copy status, checksums, sizes). Page-checksum failures never abort — they warn and record invalid pages in the manifest.

**Backup from a standby** (`backup-standby=y`): backup starts on the primary, then replicated files are copied from the standby to offload I/O; unreplicated files still come from the primary. Recovery from a standby backup is slightly less efficient because hint bits and some FSM updates aren't replicated and must be redone after recovery.

### 5.2 restore (`src/command/restore/restore.c`)
`cmdRestore()` loads the target manifest (`manifestNewLoad`) from the chosen backup set/repo (decrypting with the repo cipher chain); verifies the selected timeline; maps the manifest (`restoreManifestMap`), checks link sanity (`manifestLinkCheck`), sets ownership (`restoreManifestOwner`), builds the selective-restore zero expression (`restoreSelectiveExpression`), and cleans/builds the target tree (`restoreCleanBuild`) — with `--delta` it computes SHA-1 of existing files, keeps matches, and removes files not in the manifest. It saves the manifest into PGDATA so a delta restore can resume even if `PG_VERSION` is missing, dispatches parallel restore jobs across `process-max` local workers (`protocolParallelClientAdd(parallelExec, protocolLocalGet(protocolStorageTypeRepo, 0, processIdx))`), reports percent-complete, writes `postgresql.auto.conf` with recovery settings (plus `recovery.signal`/`standby.signal` as appropriate), and **restores `global/pg_control` last** and fsyncs it so an interrupted restore cannot start. Non-root restores adopt the executing user/group; root restores recreate the manifest ownership.

### 5.3 archive-push / archive-get (`src/command/archive/`)
`cmdArchivePush()` copies a WAL segment to all configured repos. **Synchronous** mode runs per segment before returning to PostgreSQL. **Asynchronous** mode (`archive-async=y`): the foreground process forks a background async process that uses `ProtocolParallel` with up to `process-max` workers to push multiple segments concurrently; `archivePushReadyList()` reads `archive_status/*.ready`, `archivePushProcessList()` computes what needs pushing, and status is tracked in the spool `out/` directory with `.ok`/`.error` files (`archiveAsyncStatusOkWrite`/`ErrorWrite`/`archiveAsyncStatus` in `src/command/archive/common.c`). Writes are atomic (`.pgbackrest.tmp` then rename). Identical duplicate pushes are de-duplicated; differing content for the same segment name errors. `archive-push-queue-max` protects against WAL volume filling: on exceeding it, pgBackRest tells PostgreSQL the WAL was archived and **drops it** (breaking PITR continuity) to keep PostgreSQL from PANIC/stopping. `archive-get` maintains a local decompressed queue in the spool path for fast replay and fetches from repos in priority order (repo1, repo2, …).

---

## 6. Block Incremental, Bundling, Compression, Encryption, Checksums

### 6.1 Block incremental (v2.46, `--repo-block`; v2.52.1+ recommended)
Only changed parts of files are stored. Source: `src/command/backup/blockIncr.c` (`blockIncrNew` filter), `blockChecksum.c` (`blockChecksumNew`), `blockMap.c` (`BlockMap`), and on restore `src/command/restore/blockDelta.c` (`blockDeltaNew`/`blockDeltaNext`).

- **Block size**: 8 KiB–88 KiB, all multiples of the 8 KiB page size, chosen by file size and age (larger/older files get larger blocks). Size-map thresholds (backup.c): ≥914 MiB→88 KiB (max) scaling down to ≥16 KiB→8 KiB (min). **Age map**: files ≥28 days old skip block-incremental entirely (full copy, multiplier 0); ≥14 days →4×; ≥7 days →2×.
- **Block checksum**: **xxHash** (`src/common/crypto/xxhash.c`, vendored), truncated to 6–12 bytes per a checksum-size map (<32 KiB→6B up to ≥4 MiB→12B). Distinct from the whole-file SHA-1 in the manifest.
- **Super blocks**: consecutive changed blocks sharing the same reference backup are grouped and compressed/encrypted together so they can be retrieved independently. (The commonly cited 256 KiB–1 MiB super-block range is repeated in secondary sources but should be verified against source constants.)
- **Block map** (`BlockMapItem`): `reference` (backup index, 0=current), `superBlockSize`, `bundleId`, `offset`, `size`, `block`, `checksum`. A full copy of the map is written each time a file changes; it reconstructs the file and lets restore fetch only needed blocks. Long incremental chains hurt restore because a file may require blocks pulled from many backups — keep chains short.
- Savings can be dramatic. In Crunchy Data's published demo on a 995.7 MB database, an incremental backup with block-incremental enabled (repo2) was **943.3 KB versus 52.8 MB** for the same change on the file-level repo (repo1) — described as "more than 50x improvement in backup size," because a 1 GB table segment changed by a few rows transfers a few blocks rather than the whole file.

### 6.2 File bundling (v2.39, `--repo-bundle`)
Combines small files into bundles to cut file count (dramatic on object stores); zero-length files stored only in the manifest. `repo-bundle-size` (bundle size cap before compression) and `repo-bundle-limit` (max file size eligible) tune it. Downsides: bundled files can't be resumed; harder to manually extract; suboptimal for dedup storage. Block-incremental + bundling together are recommended for new repos (with the caveat that they break backward compatibility with older pgBackRest reading the same repo).

### 6.3 Compression
`compress-type`: `gz` (zlib, default), `lz4`, `zst` (zstd, recommended — fast, gz-like ratio), `bz2` (slow, best ratio). `compress-level` is per-type range-checked (v2.44+). `compress-level-network` applies only when `compress-type=none` and the repo is remote (transit-only compression). Compression is usually the backup bottleneck — hence parallelism + zstd/lz4.

### 6.4 Encryption
`repo-cipher-type=aes-256-cbc` + `repo-cipher-pass`. **Always client-side** (even on object stores), via OpenSSL (`src/common/crypto/cipherBlock.c`). Uses a **three-tier passphrase hierarchy**: the user repo passphrase decrypts a manifest sub-passphrase (stored in the `[cipher]` section of info files), which protects per-file/backup data keys — so data-encryption keys can rotate without re-encrypting everything and the user passphrase never directly encrypts bulk data. Encryption must be set before `stanza-create`; it cannot be added to an existing repository (requires a new stanza + fresh full backup). Encrypted data doesn't compress, so with external encryption (e.g. pg_tde) compression is often disabled. Can combine with versioned/object-lock storage for ransomware protection. Generate strong passphrases with `openssl rand -base64 48`.

### 6.5 Checksums & page validation
- **File checksums**: SHA-1 (20 bytes) via OpenSSL, computed in-stream during copy, stored in the manifest, rechecked on restore/verify.
- **Page checksums** (`--checksum-page`, auto-enabled when PG data checksums are on): validated for every page during backup (all pages on full; changed files on diff/incr). Failures warn + record invalid pages in the manifest but never abort — catching corruption early before good backups expire.
- **WAL header checks** (`archive-header-check`) verify PG version/system-ID on each WAL segment; push/get compare PG version + system ID to prevent mis-targeted archives.

---

## 7. Configuration, Deployment Topologies, PostgreSQL Interaction

**Stanza concept**: a stanza is the config for one PostgreSQL cluster (location, backup, archiving options). The same stanza name is used on the primary and all replicas; name it for function (`app`, `dw`), not local cluster name. One stanza ↔ one cluster is a hard coupling.

**Cascading config**: INI at `/etc/pgbackrest/pgbackrest.conf` (+ `conf.d/`). Sections: `[global]` (shared), `[global:<command>]` (per-command global, e.g. `[global:archive-push] process-max=3`), `[<stanza>]` (per-cluster). Options are `repoN-*` / `pgN-*` indexed (N=1..8 repos, multiple pg hosts). Precedence: command-line > env (`PGBACKREST_*`) > config > default.

**PostgreSQL interaction**: non-exclusive backup API only; `pg_backup_start`/`pg_backup_stop` on PG15+, non-exclusive `pg_start_backup`/`pg_stop_backup` on PG9.6–14. pgBackRest reads `pg_control` and WAL headers **directly as binary** (`src/postgres/interface.c`) rather than via SQL where possible, so it works during offline/recovery scenarios; `pg-path` is verified against PostgreSQL's reported data_directory on every online backup. The PG query interface is tunneled through the protocol so direct network access to PostgreSQL from the repo host is never required (a security benefit). Supports 10 PG versions (5 supported + 5 EOL), through PG18.

**Topologies**:
1. **Repo on the DB host** (simplest; traditional file backup then copies the repo).
2. **Dedicated repo host** over SSH or TLS (repo host pulls; least-privilege `pgbackrest` user).
3. **Direct-to-object-store** (S3/Azure/GCS) from the DB host.
4. **Multi-repo** (v2.33, up to 8): e.g. local repo with short retention for fast restores + remote/object repo with long retention. WAL pushes to all repos; backups are scheduled per repo; restores pick a repo (priority order). Combined with async archiving, provides fault tolerance if one repo is down.

**Retention/expire model**: `repo-retention-full` (count, or days with `repo-retention-full-type=time`), `repo-retention-diff` (diff count), `repo-retention-archive` + `repo-retention-archive-type` (full/diff/incr — how much continuous WAL to keep). Expiring a full expires its dependent diff/incr. Footguns: WAL required for a backup's consistency is always retained; setting `repo-retention-archive` larger than the number of retained backups leads to effectively infinite WAL retention (documented by Data Egret's "WAL Archives Retention Trap"). Adhoc `expire --set` removes a specific backup set.

**Performance tuning knobs**: `process-max` (default 1 — almost never right; higher for restore since PG is down), `compress-type=zst`, `compress-level`, `buffer-size` (16 KiB–16 MiB; ≤3 buffers/process + ~256 KiB zlib), `io-timeout` (default 1m), `db-timeout` (< `protocol-timeout`, default 31m), `archive-async=y` + `spool-path` (local POSIX FS, not NFS/CIFS), `repo-bundle`, `repo-block`, `start-fast=y`, `delta=y`, `archive-push-queue-max`, `archive-get-queue-max`.

**Security model**: least-privilege repo user (put `postgres` in the `pgbackrest` group for read-only repo access); neutral umask (0000 → dirs 0750/files 0640); client-side encryption; **TLS server mode** (v2.37) as an SSH alternative — mutual TLS with per-stanza authorization via `tls-server-auth=<client-CN>=<stanza-list>` (or `client-cn=*`). Unlike SSH keys (which grant shell), TLS auth is per-command/stanza scoped. Caveat: pgBackRest does **not support X.509 CRLs** — revocation is done by removing the `tls-server-auth` line and restarting the server daemon, then reissuing under a new CN. `server-ping` is unauthenticated (aliveness only). TLS default port 8432.

---

## 8. History & Design Decisions

- **2013**: started by David Steele, originally in Perl. Stephen Frost provided design guidance and review throughout; both were associated with Crunchy Data, the long-term sponsor (Resonate an early production sponsor).
- **2015–2017 (v1.x)**: parallel backup, delta restore, selective DB restore, repository encryption (contributed by Cynthia Shang), page-checksum validation, S3 support, new repo/config format (the v1.00 flag-day break).
- **2018 (v2.00)**: began the multi-year rewrite from Perl to pure C. Rationale: **performance** (time-critical paths like async archive-push), fewer **runtime dependencies** (no Perl/CPAN), lower **memory footprint**, and precise control (custom protocol, streaming filters). The custom object/memory system in C (vs C++/framework) was chosen for portability, deterministic exception-safe cleanup, and minimal dependencies.
- **v2.02–2.13**: C library / Perl glue dropped as commands moved to C; archive-push/archive-get fully C by v2.13-era. Migration effectively complete by ~2019.
- **Milestones (verified against release notes)**: multi-repository **v2.33** (Apr 2021); TLS server **v2.37** (Jan 3 2022); **file bundling + verify command + PG15 + percent-complete + `--type=lsn`** in **v2.39** (Jul 2022); backup annotations **v2.41** (Sep 2022); SFTP repo storage + **block incremental (BETA)** + PG16 in **v2.46** (Jun 2023); block-incremental hardened/recommended by v2.52.1; autoconf/make removed after v2.54; final solo-era release **v2.58.0** (Jan 19 2026).
- **Docs-as-code**: XML-driven docs whose commands actually execute in containers during the build, guaranteeing accuracy.

**The 2026 maintenance crisis and revival (critical context):** David Steele maintained pgBackRest for **thirteen years**, primarily under Crunchy Data sponsorship. Snowflake acquired Crunchy Data for **$164.5 million in cash on June 6, 2025** (per Snowflake's FY2026 Form 10-Q: "On June 6, 2025, the Company acquired all of the outstanding capital stock of Crunchy Data Solutions, Inc. … for $164.5 million in cash"; press reports had estimated ~$250M). Unable to secure independent funding, Steele archived the GitHub repo (read-only) on **April 27, 2026** with a Notice of Obsolescence, writing: *"Rather than do the work poorly and/or sporadically, I think it makes more sense to have a hard stop."* v2.58.0 became the last solo-era release. By **May 1**, PostgreSQL Experts (PGX) had forked the project as **pgxbackup** (Steele requested forks not use the pgBackRest name). On **May 18, 2026**, a sponsor coalition revived the original tree; per pgbackrest.org: *"Our sponsors: AWS, Supabase, pgEdge, Tiger Data, Percona, Eon, Xata, Dalibo, Data Egret. … Past sponsors: Crunchy Data, Resonate."* The repo was unarchived, Steele returned, and onboarding a second maintainer was announced. The coalition model is explicitly designed to prevent a single acquisition ending maintenance again.

---

## 9. Gaps, Weaknesses, Critique

1. **Process-based parallelism (fork/exec), not threads.** Simpler and crash-isolated, but heavier per-worker overhead, IPC via the custom protocol, and no shared in-process memory. High file counts mean more processes coordinating over `select()`-driven dispatch.
2. **Memory-unsafe C.** No known serious CVEs, but the codebase has had fixable bugs (a possible segfault in a page-checksum error message fixed by Zsolt Parragi; a buffer overrun in error handling fixed in early 2.0x; a FINALLY-throw infinite loop fixed in v2.39). The 100%-coverage discipline and OpenSSL reliance mitigate but don't eliminate risk.
3. **Custom object/memory system learning curve.** The `*Pub`/`THIS_PUB`/`OBJ_NEW_BEGIN` pattern is powerful but verbose and unfamiliar; contributor ramp-up is steep, narrowing the maintainer pool — a factor in the 2026 bus-factor crisis.
4. **Single-maintainer / bus factor.** The April 2026 archival exposed that critical PostgreSQL infrastructure depended on one funded maintainer. Revived under a coalition, but the second maintainer was still only "planned" as of May 2026, and no post-revival release had shipped.
5. **No page-level incremental via changed-block tracking (no PTRACK).** Block-incremental (v2.46) reads the whole file to detect changed blocks (a DELTA method), so it still reads all data on the DB host even when copying little — unlike pg_probackup's PTRACK, which avoids the read (requested in issue #1806).
6. **Repository-format lock-in.** REPOSITORY_FORMAT=5; the catalog is only readable by pgBackRest. Migrating to WAL-G/Barman means a fresh full backup; existing PITR coverage is stranded. New features (bundling, block-incr) are not backward compatible with older pgBackRest reading the same repo.
7. **Tight stanza↔cluster coupling & config complexity.** One stanza per cluster; ~190 options; multi-repo and retention interactions (the WAL-retention "trap") are recurring support topics.
8. **No native Kubernetes operator.** Relies on third-party operators: Crunchy PGO and Percona Operator embed pgBackRest (coupling backup-code updates to operand images); CloudNativePG does **not** use it natively (uses the Barman Cloud plugin / volume snapshots), though a community CNPG-I pgBackRest plugin exists (operasoftware/cnpg-plugin-pgbackrest) that is S3-only and mostly tested for full-backup-to-latest restore.
9. **verify command maturity.** Introduced v2.39; validates checksums vs manifest but is comparatively young and not a substitute for periodic test restores.
10. **No built-in WAL streaming (pg_receivewal-style).** Relies on `archive_command`; no synchronous streaming receiver, so RPO is bounded by archive_timeout/WAL segment completion. No snapshot-based backup orchestration (though hardlink + uncompressed repos permit manual FS snapshots).
11. **Real-world pain points**: object-store rate limits and high file counts (addressed by bundling/block-incr), long incremental chains degrading restore, S3 bucket-name/dot TLS constraints, mandatory local/remote version matching, and no CRL support in TLS mode.

---

## 10. Operational/Feature Comparison

| Dimension | pgBackRest | Barman | WAL-G | pg_probackup | pg_basebackup + archive |
|---|---|---|---|---|---|
| Language | C | Python | Go | C | C (in-core) |
| Incremental granularity | File-level + **block-level** (DELTA, read-all) | File-level (rsync/`reuse_backup`) | File-level delta (page DELTA) | **Block-level DELTA/PAGE/PTRACK** | v17+ native block incremental |
| Parallelism | Yes (process-based) | Limited | Yes | Yes (multi-threaded) | No |
| Backup from standby | Yes (hybrid primary+standby) | Yes (WAL from primary) | Yes | Yes | Limited |
| WAL archiving | archive_command (sync/async) | pg_receivewal streaming or archive_command | wal-push/fetch + prefetch | archive-push/get | archive_command |
| Storage backends | Posix, S3, Azure, GCS, SFTP, CIFS | Local + scripts to cloud | S3, GCS, Azure, Swift | Local, S3 (limited) | Local/archive |
| Encryption | AES-256-CBC client-side | DIY | Yes | Yes | No |
| Delta restore | Yes (checksum + **block** delta) | No (file) | Delta fetch | Yes | No |
| Resume backup | **Yes** (unique) | No | No | No | No |
| Verify without restore | verify command + page checksums | DIY hooks | wal-verify | validate/checksum | No |
| K8s story | 3rd-party operators (PGO, Percona); CNPG plugin (S3-only) | CNPG Barman Cloud plugin (reference) | Zalando operator native | Limited | N/A |
| Commercial backer | Coalition (AWS, Percona, Supabase, pgEdge, Tiger Data, Eon) since May 2026 | EDB | Community (orig. Citus/Microsoft) | Postgres Pro | PGDG |
| License | **MIT** | GPLv3 | Apache 2.0 | LGPL/BSD-style | PostgreSQL |

**When to choose which:**
- **pgBackRest**: large (>500 GB) / multi-TB clusters, tight RPO/RTO, block-incremental space savings, multi-repo redundancy, object storage, delta restore for HA node rebuilds, encryption at rest. Best raw performance + unique resume capability.
- **Barman**: centralized management of many servers, EDB commercial support, streaming WAL via pg_receivewal, compliance-driven enterprises.
- **WAL-G**: cloud-native/Kubernetes, simplest object-store integration, mixed DB stacks, Go single binary. Note its file-level delta transfers an entire 1 GB segment file if one block changes, versus pgBackRest's few-block transfer.
- **pg_probackup**: multi-TB with tightest backup windows — PTRACK avoids reading unchanged blocks and synthetic full backups reduce load; Postgres Pro backing.
- **pg_basebackup + archiving**: small clusters, simple PITR, no extra tooling; hits a ceiling past a few hundred GB.
- **CloudNativePG**: if Kubernetes-first, its Barman Cloud plugin + volume snapshots are the native path (a 4.5 TB restore in ~2 minutes was demonstrated via snapshots at KubeCon); a pgBackRest CNPG-I plugin exists but is less mature.

---

## 11. Recommendations

**Staged adoption / operation:**
1. **New deployments (self-managed, >100 GB)**: adopt pgBackRest v2.58.0. Enable from day one on a fresh repo: `compress-type=zst`, `process-max` tuned per command (`[global:backup]` 4, `[global:restore]` 8, `[global:archive-push]` 3), `repo-bundle=y`, `repo-block=y`, `start-fast=y`, `archive-async=y` with a local `spool-path`. Enable PG data checksums (`initdb -k`) so page validation runs.
2. **Encryption**: decide before `stanza-create` (cannot be retrofitted). Use `aes-256-cbc` with `openssl rand -base64 48`; store the passphrase in a secrets manager — losing it means unrecoverable backups.
3. **Topology**: at scale use a dedicated repo host with **TLS server mode** (not SSH) for per-stanza certificate authorization; plan CA/cert-expiry monitoring since there is no CRL support. Add a second repo (object store, longer retention) via multi-repo for redundancy.
4. **Retention**: set `repo-retention-full` explicitly (unset warns and risks filling the repo). Understand the WAL-retention interaction; generally leave `repo-retention-archive-type=full` and don't set `repo-retention-archive` larger than the number of retained backups.
5. **Validate**: schedule `verify` regularly **and** perform real test restores at least quarterly (verify is not a substitute). Keep at least one verified full backup outside the pgBackRest catalog as migration insurance.
6. **Restore performance**: use `--delta` for HA node rebuilds; keep incremental chains short (block-incremental restore degrades with long chains).

**Benchmarks/thresholds that change the recommendation:**
- If backup windows on multi-TB OLTP remain too long even with block-incremental (because pgBackRest still reads all data): evaluate **pg_probackup PTRACK**.
- If you are **Kubernetes-first**: prefer **CloudNativePG** (Barman Cloud plugin / volume snapshots) unless you specifically need pgBackRest's block-delta profile, in which case use Crunchy PGO / Percona Operator or the CNPG-I pgBackRest plugin.
- If the coalition fails to ship a post-revival release or onboard a second maintainer within ~2–3 quarters: re-evaluate migration risk (monitor both the revived tree and the pgxbackup fork).
- If you already run **CloudNativePG**: pgBackRest's status is largely irrelevant to you; no action needed.

---

## 12. Caveats

- **Line numbers and some internal specifics** (exact `backup.c` line ranges, super-block 256 KiB–1 MiB bounds, the `.bi` extension detail) are from a DeepWiki snapshot and secondary sources; they drift across versions and should be confirmed against the source at your pinned release.
- **Maintenance status is fast-moving**: the archival→revival happened within ~3 weeks (Apr 27 → May 18, 2026). As of this writing v2.58.0 remains the latest release and no post-revival release had shipped. Verify current release and maintainer status before procurement decisions.
- **Comparison-table entries** for competing tools reflect their 2026 state (Barman v3.18.0 added experimental cloud-only block-incremental; WAL-G file-level delta; pg_probackup PTRACK requires a core patch) and may change.
- Third-party blog assessments ("Barman is the pragmatic choice," "pgBackRest is technically superior but unmaintained") were written during the April–May 2026 gap and were partly overtaken by the revival.
- pgBackRest does **not** integrate pg_receivewal-style streaming; RPO depends on WAL-archiving cadence.