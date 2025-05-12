#!/usr/bin/env bash
set -e

# -----------------------------------------------------------------------------
# Função de log
# -----------------------------------------------------------------------------
log_info() {
  echo "[INFO] $1"
}

# -----------------------------------------------------------------------------
# Variáveis globais para controle de PIDs
# -----------------------------------------------------------------------------
PG_PID=""
REDIS_PID=""
NODE_PID=""

# -----------------------------------------------------------------------------
# Função de limpeza (parada graciosa)
# -----------------------------------------------------------------------------
cleanup() {
  log_info "Recebendo sinal para encerrar, parando serviços..."

  # 1) Parar aplicação Node.js
  if [[ -n "${NODE_PID:-}" ]] && kill -0 "$NODE_PID" 2>/dev/null; then
    log_info "Parando aplicação Node.js..."
    kill -TERM "$NODE_PID"
    
    # Esperar até 10 segundos pelo término do Node
    for i in {1..10}; do
      if ! kill -0 "$NODE_PID" 2>/dev/null; then
        log_info "Node.js encerrado."
        break
      fi
      sleep 1
    done
    
    # Se ainda estiver em execução, force o encerramento
    if kill -0 "$NODE_PID" 2>/dev/null; then
      log_info "Forçando encerramento do Node.js..."
      kill -9 "$NODE_PID" || true
    fi
  fi

  # 2) Parar PostgreSQL usando pg_ctl
  if [[ -n "${PG_PID:-}" ]] && kill -0 "$PG_PID" 2>/dev/null; then
    log_info "Parando PostgreSQL graciosamente..."
    su-exec postgres pg_ctl -D "$PGDATA" -m fast stop
    
    # Aguardar até 15 segundos para o PostgreSQL terminar
    for i in {1..15}; do
      if ! kill -0 "$PG_PID" 2>/dev/null; then
        log_info "PostgreSQL encerrado com sucesso."
        break
      fi
      sleep 1
    done
    
    # Se ainda estiver em execução, tentar uma última vez
    if kill -0 "$PG_PID" 2>/dev/null; then
      log_info "PostgreSQL ainda em execução, enviando SIGTERM..."
      kill -TERM "$PG_PID" || true
      sleep 5
      
      # Se ainda não terminou, força o encerramento
      if kill -0 "$PG_PID" 2>/dev/null; then
        log_info "Forçando encerramento do PostgreSQL..."
        kill -9 "$PG_PID" || true
      fi
    fi
  fi

  # 3) Parar Redis
  if [[ -n "${REDIS_PID:-}" ]] && kill -0 "$REDIS_PID" 2>/dev/null; then
    log_info "Parando Redis..."
    redis-cli shutdown || true
    
    # Aguardar até 10 segundos para o Redis terminar
    for i in {1..10}; do
      if ! kill -0 "$REDIS_PID" 2>/dev/null; then
        log_info "Redis encerrado com sucesso."
        break
      fi
      sleep 1
    done
    
    # Se ainda estiver em execução, force o encerramento
    if kill -0 "$REDIS_PID" 2>/dev/null; then
      log_info "Forçando encerramento do Redis..."
      kill -9 "$REDIS_PID" || true
    fi
  fi

  log_info "Todos os serviços foram encerrados."
  exit 0
}

# Registrar trap para SIGTERM e SIGINT
trap cleanup SIGTERM SIGINT

# -----------------------------------------------------------------------------
# Carregamento de configurações
# -----------------------------------------------------------------------------
log_info "Carregando configurações de /data/options.json..."
CONFIG="/data/options.json"

if [ -f "$CONFIG" ]; then
  SERVER_TYPE=$(jq -r '.SERVER_TYPE // "http"' "$CONFIG")
  SERVER_HOST=$(jq -r '.SERVER_HOST // "homeassistant"' "$CONFIG")
  SERVER_PORT=$(jq -r '.SERVER_PORT // 49152' "$CONFIG")
  TZ=$(jq -r '.TZ // "America/Sao_Paulo"' "$CONFIG")
  DATABASE_USER=$(jq -r '.DATABASE_USER // "user"' "$CONFIG")
  DATABASE_PASSWORD=$(jq -r '.DATABASE_PASSWORD // "pass"' "$CONFIG")
  DATABASE_PROVIDER=$(jq -r '.DATABASE_PROVIDER // "postgresql"' "$CONFIG")
  DATABASE_CONNECTION_URI=$(jq -r '.DATABASE_CONNECTION_URI // "postgresql://user:pass@localhost:5432/evolution?schema=public"' "$CONFIG")
  AUTHENTICATION_API_KEY=$(jq -r '.AUTHENTICATION_API_KEY // "minha-senha-secreta"' "$CONFIG")
fi

export DATABASE_USER
export DATABASE_PASSWORD
export SERVER_PORT
export SERVER_HOST
export SERVER_TYPE
export TZ
export DATABASE_PROVIDER
export DATABASE_CONNECTION_URI
export AUTHENTICATION_API_KEY
export SERVER_URL="http://${SERVER_HOST}:${SERVER_PORT}"

log_info "Server URL set to $SERVER_URL"

# -----------------------------------------------------------------------------
# Preparação de diretórios
# -----------------------------------------------------------------------------
log_info "Criando diretórios de persistência em /data e /run..."
mkdir -p /data/postgresql /data/redis /run/postgresql /run/redis
chown -R postgres:postgres /data/postgresql /run/postgresql
chown -R redis:redis /data/redis /run/redis

# -----------------------------------------------------------------------------
# Inicialização do PostgreSQL
# -----------------------------------------------------------------------------
# Inicialização do banco de dados, se necessário
if [ ! -f "$PGDATA/PG_VERSION" ]; then
  log_info "Inicializando banco de dados PostgreSQL..."
  su-exec postgres initdb --auth-local=trust --auth-host=trust
fi

# Verificar e remover postmaster.pid se necessário
if [ -f "$PGDATA/postmaster.pid" ]; then
  PID=$(head -1 "$PGDATA/postmaster.pid" 2>/dev/null || echo "")
  if [ -n "$PID" ] && ! ps -p "$PID" > /dev/null; then
    log_info "Removendo arquivo de PID desatualizado do PostgreSQL..."
    rm -f "$PGDATA/postmaster.pid"
  fi
fi

# -----------------------------------------------------------------------------
# Iniciar Redis
# -----------------------------------------------------------------------------
log_info "Iniciando Redis (foreground)..."
su-exec redis redis-server \
  --dir /data/redis \
  --unixsocket /run/redis/redis.sock \
  --appendonly yes \
  --appendfilename appendonly.aof \
  --save 60 1 \
  --save 300 10 \
  --save 900 1 &
REDIS_PID=$!

# -----------------------------------------------------------------------------
# Iniciar PostgreSQL
# -----------------------------------------------------------------------------
log_info "Iniciando PostgreSQL (foreground)..."
su-exec postgres postgres -D "$PGDATA" -c listen_addresses=localhost &
PG_PID=$!

# Aguardar PostgreSQL iniciar
log_info "Aguardando PostgreSQL aceitar conexões..."
for i in $(seq 1 10); do
  log_info "Tentativa $i/10..."
  if su-exec postgres pg_isready -h localhost -U postgres > /dev/null 2>&1; then
    log_info "PostgreSQL está pronto!"
    break
  fi
  
  # Se chegamos na última tentativa e ainda não conectou, abortar
  if [ $i -eq 10 ]; then
    log_info "PostgreSQL não respondeu após 10 tentativas, abortando..."
    cleanup
    exit 1
  fi
  
  sleep 2
done

# -----------------------------------------------------------------------------
# Configurar banco de dados
# -----------------------------------------------------------------------------
# Verificar se usuário já existe
USER_EXISTS=$(su-exec postgres psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='${DATABASE_USER}'")

if [ "$USER_EXISTS" != "1" ]; then
  log_info "Criando usuário ${DATABASE_USER}..."
  su-exec postgres psql -c "CREATE ROLE \"${DATABASE_USER}\" LOGIN PASSWORD '${DATABASE_PASSWORD}';"
else
  log_info "Usuário ${DATABASE_USER} já existe."
fi

# Verificar se banco de dados já existe
DB_EXISTS=$(su-exec postgres psql -tAc "SELECT 1 FROM pg_database WHERE datname='evolution'")

if [ "$DB_EXISTS" != "1" ]; then
  log_info "Criando banco de dados evolution..."
  su-exec postgres psql -c "CREATE DATABASE evolution OWNER \"${DATABASE_USER}\";"
else
  log_info "Banco de dados evolution já existe."
fi

su-exec postgres psql -c "GRANT ALL PRIVILEGES ON DATABASE evolution TO \"${DATABASE_USER}\";"

# -----------------------------------------------------------------------------
# Executar migrations e iniciar aplicação
# -----------------------------------------------------------------------------
log_info "Executando migrations de banco de dados..."
cd /evolution
./Docker/scripts/deploy_database.sh

echo ""
echo "┌───────────────────────────────────────────────────────────────────────────────────────┐"
echo "│ Database USER: $DATABASE_USER"
echo "| Database PASS: $DATABASE_PASSWORD"
echo "│ Database URL: $DATABASE_CONNECTION_URI"
echo "│ Server URL: $SERVER_URL"
echo "└───────────────────────────────────────────────────────────────────────────────────────┘"
echo ""

log_info "Iniciando aplicação Node.js..."
node dist/main 2>&1 | iconv -f ISO-8859-1 -t UTF-8 -c &
NODE_PID=$!

# Aguardar por algum dos processos terminar
wait -n "$PG_PID" "$REDIS_PID" "$NODE_PID" || true

# Se chegamos aqui, um dos processos terminou
log_info "Um dos serviços terminou inesperadamente. Encerrando todos os serviços..."
cleanup
