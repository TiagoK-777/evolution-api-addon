# syntax=docker/dockerfile:1

# --- Add-on Dockerfile usando imagem p�blica atendai/evolution-api:v2.1.1 ---

# 1) Base Supervisor
ARG BUILD_FROM=ghcr.io/home-assistant/amd64-base:latest
FROM ${BUILD_FROM} AS base

# 2) Puxe a aplica��o j� constru�da da imagem oficial
FROM atendai/evolution-api:v2.2.3 AS app

# 3) Runtime: base + PostgreSQL + Redis + App
FROM ${BUILD_FROM}

# --- Vari�veis de ambiente ---
ENV TZ=America/Sao_Paulo \
    DOCKER_ENV=true \
    PGDATA=/data/postgresql \
    REDIS_URL=redis://localhost:6379

# --- Instala depend�ncias: Postgres, Redis, utilit�rios e tzdata ---
RUN apk update \
    && apk add --no-cache \
       postgresql postgresql-contrib su-exec \
       redis \
	   jq \
       ffmpeg bash openssl tzdata \
    && rm -rf /var/cache/apk/*

# Diret�rio de trabalho (app)
WORKDIR /evolution

# --- Copia a aplica��o pr�-buildada ---
COPY --from=app /evolution /evolution

# --- Cria e ajusta diret�rios de dados ---
RUN mkdir -p "$PGDATA" /run/postgresql /run/redis \
    && chown -R postgres:postgres "$PGDATA" /run/postgresql \
    && chown -R redis:redis /run/redis

# --- Copia e d� permiss�o ao script de inicializa��o ---
COPY run.sh /run.sh
RUN chmod +x /run.sh

# --- Ponto de entrada: inicia Redis + init DB + start Postgres + migrations + API ---
ENTRYPOINT ["sh", "/run.sh"]
