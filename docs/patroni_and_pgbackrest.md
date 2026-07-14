# Patroni & pgBackRest

Patroni does not use pgBackRest by default, but it fully supports integration with it. [1, 2]
While Patroni focuses strictly on managing High Availability (HA) and automated failovers, it does not include built-in disaster recovery or backup features. To bridge this gap, database administrators frequently couple Patroni with pgBackRest to handle backups, point-in-time recovery (PITR), and node bootstrapping. [1, 3, 4]

## How Patroni and pgBackRest Work Together
Instead of relying on native PostgreSQL tools, you can configure Patroni to delegate specific tasks to pgBackRest within its configuration file (patroni.yml): [5]

* Cluster Bootstrapping: You can configure Patroni’s bootstrap.method to use pgbackrest instead of initdb. This allows a brand-new Patroni cluster node to build itself directly from an existing pgBackRest backup. [6, 7]
* Replica Creation: Under the pg_basebackup configuration section, you can define a custom create_replica_methods. Setting this to use pgBackRest allows new or broken standby nodes to sync faster by downloading delta backups rather than streaming the entire database over the network from the primary node. [5]
* WAL Archiving: Patroni safely manages the PostgreSQL configuration parameters (archive_command and archive_mode). You can direct these parameters to trigger pgBackRest to push Write-Ahead Logs (WAL) to a centralized repository. [8, 9, 10]


[1] [https://www.youtube.com](https://www.youtube.com/watch?v=MAoUFIIedFs&t=197)
[2] [https://serverspace.io](https://serverspace.io/support/help/what-is-a-patroni-cluster-and-how-does-it-work/)
[3] [https://www.quadrata.it](https://www.quadrata.it/building-a-bulletproof-postgresql-cluster-with-patroni-etcd-and-pgbackrest/)
[4] [https://github.com](https://github.com/NinaWendy/postgresql-ha-backup-with-pgbackrest)
[5] [https://github.com](https://github.com/patroni/patroni/discussions/3561)
[6] [https://github.com](https://github.com/patroni/patroni/issues/2357)
[7] [https://github.com](https://github.com/autobase-tech/autobase/issues/560)
[8] [https://github.com](https://github.com/patroni/patroni/issues/1734)
[9] [https://docs.gitlab.com](https://docs.gitlab.com/administration/postgresql/replication_and_failover/)
[10] [https://dev.to](https://dev.to/beefedai/incremental-forever-backup-architecture-for-postgresql-569e)
