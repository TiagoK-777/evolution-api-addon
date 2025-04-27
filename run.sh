#!/usr/bin/with-contenv bash
set -eux

# 0) Persistência em /data
mkdir -p /data/postgresql /data/redis
chown -R postgres:postgres /data/postgresql
chown -R redis:redis     /data/redis

# 1) InitDB se for primeira vez
if [ ! -f "$PGDATA/PG_VERSION" ]; then
  echo "[db] initdb (trust)…"
  su-exec postgres initdb --auth-local=trust --auth-host=trust
fi

# 2) Sockets efêmeros
mkdir -p /run/postgresql /run/redis
chown postgres:postgres /run/postgresql
chown redis:redis     /run/redis

# 3) Start Redis com persistência
echo "[redis] starting…"
su-exec redis redis-server \
  --daemonize yes \
  --dir /data/redis \
  --unixsocket /run/redis/redis.sock \
  --appendonly yes \
  --appendfilename appendonly.aof \
  --save 60 1 \
  --save 300 10 \
  --save 900 1

# 4) Start Postgres
echo "[db] starting…"
su-exec postgres postgres -D "$PGDATA" -c listen_addresses=localhost &
sleep 2

# 5) Garante role “user”
psql -v ON_ERROR_STOP=1 --username postgres <<-'EOSQL'
DO
$$
  BEGIN
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'user') THEN
      CREATE ROLE "user" LOGIN PASSWORD 'pass';
    END IF;
  END
$$;
EOSQL

# 6) Garante DB “evolution”
if [ "$(psql -U postgres -tAc "SELECT 1 FROM pg_database WHERE datname='evolution'")" != "1" ]; then
  echo "[db] creating evolution…"
  psql --username postgres -c "CREATE DATABASE evolution OWNER \"user\";"
else
  echo "[db] evolution already exists, skipping."
fi
psql --username postgres -c "GRANT ALL PRIVILEGES ON DATABASE evolution TO \"user\";"

# 7) Migrations e API
export DATABASE_CONNECTION_URI="postgresql://user:pass@localhost:5432/evolution?schema=public"
cd /evolution
./Docker/scripts/deploy_database.sh

echo "[app] exec Node…"
exec node dist/main
