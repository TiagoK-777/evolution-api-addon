#!/usr/bin/with-contenv bash
set -eux

CONFIG="/data/options.json"
if [ -f "$CONFIG" ]; then
  echo "[run.sh] Carregando configuracoes de $CONFIG..."
  # Para cada variável, leia do JSON se existir, senão mantenha o default
  SERVER_TYPE=$(jq -r '.SERVER_TYPE // "http"' "$CONFIG")
  SERVER_HOST=$(jq -r '.SERVER_HOST // "homeassistant"' "$CONFIG")
  SERVER_PORT=$(jq -r '.SERVER_PORT // 49152' "$CONFIG")
  TZ=$(jq -r '.TZ // "America/Sao_Paulo"' "$CONFIG")
  DATABASE_PROVIDER=$(jq -r '.DATABASE_PROVIDER // "postgresql"' "$CONFIG")
  DATABASE_CONNECTION_URI=$(jq -r '.DATABASE_CONNECTION_URI // "postgresql://user:pass@localhost:5432/evolution?schema=public"' "$CONFIG")
  AUTHENTICATION_API_KEY=$(jq -r '.AUTHENTICATION_API_KEY // "minha-senha-secreta"' "$CONFIG")
  
  export SERVER_PORT
  export SERVER_HOST
  export SERVER_TYPE
  export TZ
  export DATABASE_PROVIDER
  export DATABASE_CONNECTION_URI
  export AUTHENTICATION_API_KEY
fi

# monta e exporta o SERVER_URL
export SERVER_URL="http://${SERVER_HOST}:${SERVER_PORT}"
echo "[run.sh] Server URL set to $SERVER_URL"

# 0) Persistência em /data
mkdir -p /data/postgresql /data/redis
chown -R postgres:postgres /data/postgresql
chown -R redis:redis     /data/redis

# 1) InitDB se for primeira vez
if [ ! -f "$PGDATA/PG_VERSION" ]; then
  echo "[db] initdb (trust)..."
  su-exec postgres initdb --auth-local=trust --auth-host=trust
fi

# 2) Sockets efêmeros
mkdir -p /run/postgresql /run/redis
chown postgres:postgres /run/postgresql
chown redis:redis     /run/redis

# 3) Start Redis com persistência
echo "[redis] starting..."
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
echo "[db] starting..."
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
  echo "[db] creating evolution..."
  psql --username postgres -c "CREATE DATABASE evolution OWNER \"user\";"
else
  echo "[db] evolution already exists, skipping."
fi
psql --username postgres -c "GRANT ALL PRIVILEGES ON DATABASE evolution TO \"user\";"

# 7) Migrations e API
#export DATABASE_CONNECTION_URI="postgresql://user:pass@localhost:5432/evolution?schema=public"
DATABASE_CONNECTION_URI=${DATABASE_CONNECTION_URI}

echo "[run.sh] Sobrescreveu /evolution/.env:"
cat /evolution/.env

cd /evolution
./Docker/scripts/deploy_database.sh

echo "[app] exec Node..."
#exec node dist/main
exec sh -c 'node dist/main 2>&1 | iconv -f ISO-8859-1 -t UTF-8 -c'
