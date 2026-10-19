#!/usr/bin/env bash
set -euo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")"

image=${1:?Usage: bash init.sh ghcr.io/thetoadsage/aiostreams:sha-<40 hex commit> (or @sha256:<64 hex digest>)}
if [[ ! "$image" =~ ^ghcr\.io/thetoadsage/aiostreams(:sha-[a-f0-9]{40}|@sha256:[a-f0-9]{64})$ ]]; then
  echo 'Use a published full-commit tag or digest from this fork.' >&2
  exit 1
fi
if [[ -e .env || -L .env ]]; then
  echo 'Staging .env already exists; refusing to replace its encryption key.' >&2
  exit 1
fi
if [[ -e data && ( ! -d data || -n "$(ls -A data)" ) ]]; then
  echo 'Staging data must be a new, empty directory. Never reuse production data.' >&2
  exit 1
fi

umask 077
mkdir -p data backups
secret=$(openssl rand -hex 32)
password=$(openssl rand -hex 24)
# noclobber prevents two simultaneous initializations replacing each other's key.
( set -o noclobber
  printf 'AIOSTREAMS_IMAGE=%s\nSECRET_KEY=%s\nAIOSTREAMS_AUTH=staging:%s\n' \
    "$image" "$secret" "$password" > .env
)
chmod 600 .env
echo 'Created isolated staging configuration. The password is in .env; keep it private.'
echo 'Validate with: docker compose -p aiostreams-staging config --quiet'
