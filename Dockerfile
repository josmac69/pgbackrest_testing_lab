FROM ubuntu:24.04

# Avoid prompts
ENV DEBIAN_FRONTEND=noninteractive

# Install dependencies, PostgreSQL, and pgBackRest
RUN apt-get update && apt-get install -y \
    curl \
    gnupg \
    lsb-release \
    sudo \
    openssh-server \
    openssh-client \
    gosu \
    procps \
    iproute2 \
    systemctl \
    && curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc | gpg --dearmor -o /etc/apt/trusted.gpg.d/postgresql.gpg \
    && echo "deb http://apt.postgresql.org/pub/repos/apt $(lsb_release -cs)-pgdg main" > /etc/apt/sources.list.d/pgdg.list \
    && apt-get update && apt-get install -y \
    postgresql-16 \
    postgresql-client-16 \
    pgbackrest \
    && rm -rf /var/lib/apt/lists/*

# Clean up default cluster created by apt package installation
RUN pg_dropcluster 16 main || true

# Setup SSH Server
RUN mkdir /var/run/sshd
# Allow postgres user to login via SSH (ssh shell must be /bin/bash)
RUN usermod -s /bin/bash postgres

# Setup SSH Keys for postgres user
RUN mkdir -p /var/lib/postgresql/.ssh && \
    ssh-keygen -t rsa -b 2048 -f /var/lib/postgresql/.ssh/id_rsa -N "" && \
    cp /var/lib/postgresql/.ssh/id_rsa.pub /var/lib/postgresql/.ssh/authorized_keys && \
    echo "Host *\n    StrictHostKeyChecking no\n    UserKnownHostsFile=/dev/null" > /var/lib/postgresql/.ssh/config && \
    chown -R postgres:postgres /var/lib/postgresql/.ssh && \
    chmod 700 /var/lib/postgresql/.ssh && \
    chmod 600 /var/lib/postgresql/.ssh/*

# Setup directories for pgBackRest
RUN mkdir -p /var/lib/pgbackrest /var/log/pgbackrest /spool/pgbackrest /etc/pgbackrest && \
    chown -R postgres:postgres /var/lib/pgbackrest /var/log/pgbackrest /spool/pgbackrest /etc/pgbackrest && \
    chmod 750 /var/lib/pgbackrest /var/log/pgbackrest /spool/pgbackrest /etc/pgbackrest

# Configure sudo for postgres user so they can run commands (like starting sshd or running tests)
RUN echo "postgres ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/postgres

# Copy entrypoint
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# Expose PG and SSH ports
EXPOSE 5432 22

ENTRYPOINT ["/entrypoint.sh"]
