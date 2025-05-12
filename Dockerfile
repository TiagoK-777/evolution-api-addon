# syntax=docker/dockerfile:1

# --- Add-on Dockerfile usando imagem pública atendai/evolution-api:v2.1.1 ---

# 1) Base Supervisor
ARG BUILD_FROM=ghcr.io/home-assistant/amd64-base:latest
FROM ${BUILD_FROM} AS base

# 2) Puxe a aplicação já construída da imagem oficial
FROM atendai/evolution-api:v2.2.3 AS app

# 3) Runtime: base + PostgreSQL + Redis + App
FROM ${BUILD_FROM}

# --- Variáveis de ambiente ---
ENV TZ=America/Sao_Paulo \
    DOCKER_ENV=true \
    PGDATA=/data/postgresql \
    REDIS_URL=redis://localhost:6379

# --- Instala dependências: Postgres, Redis, utilitários e tzdata ---
RUN apk update \
    && apk add --no-cache \
       postgresql17 \
       postgresql17-contrib \
       su-exec \
       redis \
	   jq \
       ffmpeg bash openssl tzdata \
    && rm -rf /var/cache/apk/*

# Diretório de trabalho (app)
WORKDIR /evolution

# --- Copia a aplicação pré-buildada ---
COPY --from=app /evolution /evolution

# --- Cria e ajusta diretórios de dados ---
RUN mkdir -p "$PGDATA" /run/postgresql /run/redis \
    && chown -R postgres:postgres "$PGDATA" /run/postgresql \
    && chown -R redis:redis /run/redis

# --- Copia e dá permissão ao script de inicialização ---
COPY run.sh /run.sh
RUN chmod +x /run.sh

# --- Ponto de entrada: inicia Redis + init DB + start Postgres + migrations + API ---
ENTRYPOINT ["sh", "/run.sh"]