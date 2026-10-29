#!/bin/bash
# Runs ON a private server. The Jenkins pipeline calls it over SSH; you can also run it by hand:
#
#   ~/app/deploy/update-private.sh <private1|private2> <image tag>
#   e.g. ~/app/deploy/update-private.sh private2 3f9c2ab      (a tag Jenkins pushed)
#        ~/app/deploy/update-private.sh private2 latest
#
# It pins the app image to <tag> (APP_TAG in that folder's .env), pulls it, restarts the
# app container, and waits until the container reports "healthy" (= connected to MongoDB).
# If anything fails it puts the previous tag back automatically and exits with an error.
# MongoDB (on private1) is never restarted by this script.
set -euo pipefail

die() { echo "ERROR: $*" >&2; exit 1; }

[ "$#" -eq 2 ] || die "usage: $0 <private1|private2> <image tag>"
ROLE="$1"; TAG="$2"
[[ "$ROLE" =~ ^private[12]$ ]]      || die "first argument must be private1 or private2"
[[ "$TAG"  =~ ^[A-Za-z0-9._-]+$ ]]  || die "second argument must be an image tag such as 3f9c2ab or latest"

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/$ROLE" && pwd)"
cd "$DIR"
[ -f .env ] || die "$DIR/.env not found. Create it first: cp .env.example .env  (see AWS-GUIDE.md, Part C)"

CONTAINER=user-profile-app
TIMEOUT="${HEALTH_TIMEOUT:-120}"     # seconds to wait for "healthy"
INTERVAL="${HEALTH_INTERVAL:-3}"

PREV="$(grep -E '^APP_TAG=' .env | tail -n 1 | cut -d= -f2- | tr -d '\r"' || true)"

# Set (or, with an empty argument, remove) APP_TAG in .env without touching the other lines.
set_tag() {
  { grep -v '^APP_TAG=' .env || true; } > .env.tmp
  [ -z "$1" ] || echo "APP_TAG=$1" >> .env.tmp
  cat .env.tmp > .env          # write through, so ownership and permissions of .env stay as they were
  rm -f .env.tmp
}

wait_healthy() {
  local waited=0 status="missing"
  while [ "$waited" -lt "$TIMEOUT" ]; do
    status="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$CONTAINER" 2>/dev/null || echo missing)"
    [ "$status" = healthy ] && return 0
    sleep "$INTERVAL"; waited=$((waited + INTERVAL))
  done
  echo "Container '$CONTAINER' did not become healthy within ${TIMEOUT}s (last status: $status)." >&2
  return 1
}

rollback() {
  echo "Rolling back to ${PREV:-latest} ..." >&2
  docker compose logs --tail 40 app >&2 || true
  set_tag "$PREV"
  docker compose up -d >&2 || true
  if wait_healthy; then echo "[$ROLE] rolled back to ${PREV:-latest}; the failed version is NOT running." >&2
  else echo "[$ROLE] WARNING: the rollback is not healthy either. Check: docker compose logs app" >&2; fi
  exit 1
}

echo "[$ROLE] deploying image tag $TAG (previous: ${PREV:-latest})"
set_tag "$TAG"
docker compose pull app   || rollback
docker compose up -d      || rollback
wait_healthy              || rollback

docker image prune -f >/dev/null 2>&1 || true
echo "[$ROLE] OK: $CONTAINER is healthy on tag $TAG"
