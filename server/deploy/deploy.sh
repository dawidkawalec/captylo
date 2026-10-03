#!/usr/bin/env bash
# The remote commands expand $STACK on this Mac on purpose.
# shellcheck disable=SC2029
# Deploys server/ to the VPS as the compose stack captylo-api and waits until it is healthy.
#
#   server/deploy/deploy.sh          asks before touching the VPS
#   server/deploy/deploy.sh --yes    no question (only when the owner has already said yes)
#
# Needs: DEPLOY_HOST and DEPLOY_STACK (the environment or deploy/local.env at the repo root, see
# deploy/local.env.example), ssh access to that host, $DEPLOY_STACK/.env filled on the server
# (see server/.env.example), the Caddy block from deploy/Caddyfile.snippet in place.
# The script never copies .env, node_modules or dist, and never prints a secret.
set -euo pipefail

SERVER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# deploy/local.env (git-ignored) names the server; an environment variable of the same name wins.
LOCAL_ENV="$SERVER_DIR/../deploy/local.env"
if [[ -f "$LOCAL_ENV" ]]; then
  while IFS='=' read -r key value; do
    [[ "$key" =~ ^[A-Z_]+$ ]] || continue
    [[ -n "${!key:-}" ]] || export "$key=$value"
  done < "$LOCAL_ENV"
fi
HOST="${DEPLOY_HOST:?set DEPLOY_HOST in deploy/local.env (see deploy/local.env.example)}"
STACK="${DEPLOY_STACK:?set DEPLOY_STACK in deploy/local.env (see deploy/local.env.example)}"
VERSION="$(git -C "$SERVER_DIR" describe --always --dirty 2>/dev/null || echo unknown)"

if [[ "${1:-}" != "--yes" ]]; then
  printf 'Deploy captylo-api %s to %s:%s? Type "deploy" to continue: ' "$VERSION" "$HOST" "$STACK"
  read -r answer
  [[ "$answer" == "deploy" ]] || { echo "Cancelled."; exit 1; }
fi

if [[ "$VERSION" == *-dirty ]]; then
  echo "Warning: server/ has uncommitted changes; the deployed version is $VERSION."
fi

echo "==> Checking the stack directory and .env on $HOST"
ssh "$HOST" "test -d '$STACK' && test -f '$STACK/.env'" || {
  echo "Missing $STACK or $STACK/.env on $HOST. Create them first (server/README.md, Deploy)."
  exit 1
}

echo "==> Syncing sources"
rsync -az --delete \
  --exclude node_modules --exclude dist --exclude coverage \
  --exclude .env --exclude '.env.*' --exclude .DS_Store \
  "$SERVER_DIR/" "$HOST:$STACK/src/"
rsync -az "$SERVER_DIR/deploy/docker-compose.yml" "$HOST:$STACK/docker-compose.yml"

echo "==> Building and starting"
ssh "$HOST" "cd '$STACK' && docker compose build --pull && docker compose up -d"

echo "==> Waiting for the health check"
for _ in $(seq 1 45); do
  status="$(ssh "$HOST" "docker inspect -f '{{.State.Health.Status}}' captylo-api 2>/dev/null" || true)"
  if [[ "$status" == "healthy" ]]; then
    echo "captylo-api $VERSION is healthy on $HOST."
    exit 0
  fi
  sleep 2
done

echo "captylo-api did not become healthy in 90 s (last status: ${status:-unknown})."
echo "Logs: ssh $HOST 'docker logs --tail 50 captylo-api'"
exit 1
