#!/bin/bash
# Runs ONCE, automatically, on a fresh Postgres data dir (Postgres executes every file
# in /docker-entrypoint-initdb.d on first init). On a wiped-and-recreated box this fully
# replaces the old manual `docker exec ... CREATE ROLE/DATABASE` step.
#
# Creates prizm-lodge's own least-privilege role + database on this shared instance, so
# the co-hosted provider can connect over the `data` network with credentials separate
# from CRM's. The guards make it safe to re-run by hand (psql -f) as well.
set -euo pipefail

: "${PRIZM_DB_PASSWORD:?PRIZM_DB_PASSWORD must be set for the prizm bootstrap}"

# Connect as the cluster superuser ($POSTGRES_USER) over the local socket. The password
# is passed as a psql variable and quoted with quote_literal() in the generated command,
# so it is never interpolated unsafely.
psql -v ON_ERROR_STOP=1 -v prizm_pw="$PRIZM_DB_PASSWORD" \
  --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<-'SQL'
	SELECT 'CREATE ROLE prizm LOGIN PASSWORD ' || quote_literal(:'prizm_pw')
	WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'prizm')\gexec

	SELECT 'CREATE DATABASE prizm OWNER prizm'
	WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'prizm')\gexec
SQL
