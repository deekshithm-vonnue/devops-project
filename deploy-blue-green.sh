#!/usr/bin/env bash
set -Eeuo pipefail

# Deployment settings
PROJECT="devops-project"
DEPLOY_DIR="${DEPLOY_DIR:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)}"
COMPOSE_FILE="${COMPOSE_FILE:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/compose.blue-green.yaml}"
UPSTREAM_FILE="$DEPLOY_DIR/nginx/upstream/active-upstream.conf"
HEALTH_URL="${HEALTH_URL:-http://localhost:8080/health}"

# Require a full Git commit SHA.
IMAGE_TAG="${IMAGE_TAG:-}"

if [[ ! "$IMAGE_TAG" =~ ^[0-9a-f]{40}$ ]]; then
  echo "ERROR: IMAGE_TAG must be a full 40-character Git commit SHA."
  exit 1
fi

if [[ ! -f "$COMPOSE_FILE" ]]; then
  echo "ERROR: Compose file not found: $COMPOSE_FILE"
  exit 1
fi

if [[ ! -f "$UPSTREAM_FILE" ]]; then
  echo "ERROR: Upstream file not found: $UPSTREAM_FILE"
  exit 1
fi

# Prevent overlapping deployments on this machine.
exec 9>/tmp/devops-bg-deploy.lock

if ! flock -n 9; then
  echo "ERROR: Another Blue-Green deployment is running."
  exit 1
fi

compose() {
  docker compose \
    --project-directory "$DEPLOY_DIR" \
    -p "$PROJECT" \
    -f "$COMPOSE_FILE" \
    "$@"
}

# Identify the currently active Nginx backend.
PREVIOUS="$(
  awk '
    /^[[:space:]]*server[[:space:]]+/ {
      split($2, parts, ":")
      print parts[1]
      exit
    }
  ' "$UPSTREAM_FILE"
)"

if [[ "$PREVIOUS" != "blue" && "$PREVIOUS" != "green" ]]; then
  echo "ERROR: Cannot determine the active Blue-Green service."
  exit 1
fi

# Automatically choose the inactive service.
if [[ "$PREVIOUS" == "blue" ]]; then
  TARGET="green"
else
  TARGET="blue"
fi

echo "=========================================="
echo "Blue-Green deployment"
echo "Commit:          $IMAGE_TAG"
echo "Previous active: $PREVIOUS"
echo "Deployment slot: $TARGET"
echo "=========================================="

# Validate the configuration without changing containers.
compose config -q

# Download only the target service's new image.
echo "Pulling the new image for $TARGET..."
compose pull "$TARGET"

# Recreate only the inactive service.
# The currently active service and Nginx remain running.
echo "Recreating inactive service: $TARGET..."
compose up -d --no-deps --force-recreate "$TARGET"

# Wait until the target container is healthy.
echo "Waiting for $TARGET to become healthy..."

HEALTHY=false

for attempt in $(seq 1 40); do
  CONTAINER_ID="$(compose ps -q "$TARGET")"

  if [[ -n "$CONTAINER_ID" ]]; then
    HEALTH_STATUS="$(
      docker inspect \
        --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}no-healthcheck{{end}}' \
        "$CONTAINER_ID"
    )"

    echo "Health check $attempt/40: $HEALTH_STATUS"

    if [[ "$HEALTH_STATUS" == "healthy" ]]; then
      HEALTHY=true
      break
    fi

    if [[ "$HEALTH_STATUS" == "unhealthy" || "$HEALTH_STATUS" == "no-healthcheck" ]]; then
      break
    fi
  fi

  sleep 2
done

if [[ "$HEALTHY" != "true" ]]; then
  echo "ERROR: $TARGET did not become healthy."
  compose logs --tail=100 "$TARGET" || true
  echo "Traffic remains routed to $PREVIOUS."
  exit 1
fi

# Save the exact current upstream for rollback.
BACKUP_FILE="$(mktemp "$DEPLOY_DIR/nginx/upstream/active-upstream.XXXXXX")"
cp "$UPSTREAM_FILE" "$BACKUP_FILE"

cleanup() {
  rm -f "$BACKUP_FILE"
}
trap cleanup EXIT

# Restore and verify the previous route if deployment verification fails.
rollback() {
  echo "ERROR: Deployment verification failed."
  echo "Rolling back traffic to $PREVIOUS..."

  # Restore the previous Nginx upstream configuration.
  if ! cp "$BACKUP_FILE" "$UPSTREAM_FILE"; then
    echo "CRITICAL: Could not restore the upstream configuration."
    return 1
  fi

  # Validate the restored configuration, even if Nginx is stopped.
  if ! compose run --rm --no-deps nginx nginx -t; then
    echo "CRITICAL: Restored Nginx configuration is invalid."
    return 1
  fi

  # Ensure Nginx is running.
  if ! compose up -d --no-deps nginx; then
    echo "CRITICAL: Could not start Nginx during rollback."
    return 1
  fi

  # Reload the restored configuration.
  if ! compose exec -T nginx nginx -s reload; then
    echo "CRITICAL: Could not reload Nginx during rollback."
    return 1
  fi

  # Verify that traffic is restored.
  for attempt in $(seq 1 10); do
    if curl -fsS "$HEALTH_URL" >/dev/null; then
      echo "Rollback verified. Traffic is routed to $PREVIOUS."
      return 0
    fi

    sleep 2
  done

  echo "CRITICAL: Rollback health verification failed."
  return 1
}

# Write the new upstream atomically.
echo "Switching traffic from $PREVIOUS to $TARGET..."

TEMP_UPSTREAM="$(mktemp "$DEPLOY_DIR/nginx/upstream/active-upstream.XXXXXX")"
printf 'server %s:3000;\n' "$TARGET" > "$TEMP_UPSTREAM"
mv "$TEMP_UPSTREAM" "$UPSTREAM_FILE"

# Validate the changed configuration before applying it.
if ! compose exec -T nginx nginx -t; then
  rollback || true
  exit 1
fi

# Apply the upstream change.
if ! compose exec -T nginx nginx -s reload; then
  rollback || true
  exit 1
fi

# Verify the application through the actual Nginx entry point.
echo "Verifying application through Nginx..."

for attempt in $(seq 1 10); do
  if curl -fsS "$HEALTH_URL" >/dev/null; then
    echo "=========================================="
    echo "DEPLOYMENT SUCCESSFUL"
    echo "Commit: $IMAGE_TAG"
    echo "Active service: $TARGET"
    echo "Previous service: $PREVIOUS"
    echo "=========================================="
    exit 0
  fi

  echo "Nginx health check $attempt/10 failed."
  sleep 2
done

if ! rollback; then
  echo "CRITICAL: Automatic rollback could not be fully verified."
fi

exit 1