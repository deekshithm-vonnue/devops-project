```bash
#!/usr/bin/env bash
set -Eeuo pipefail

# Deployment settings
PROJECT="devops-project"

DEPLOY_DIR="${DEPLOY_DIR:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)}"

COMPOSE_FILE="${COMPOSE_FILE:-$DEPLOY_DIR/compose.blue-green.yaml}"

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

# Prevent overlapping deployments.
exec 9>/tmp/devops-project-deploy.lock

if ! flock -n 9; then
  echo "ERROR: Another deployment is running."
  exit 1
fi

# Docker Compose wrapper.
compose() {
  docker compose \
    --project-directory "$DEPLOY_DIR" \
    -p "$PROJECT" \
    -f "$COMPOSE_FILE" \
    "$@"
}

# Identify the currently active backend.
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
  echo "ERROR: Cannot determine the active backend."
  exit 1
fi

# Select the inactive service.
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

# Validate Compose configuration.
compose config -q

# Pull the new image.
echo "Pulling image for $TARGET..."
compose pull "$TARGET"

# Recreate only the inactive application.
echo "Recreating inactive service: $TARGET..."

compose up -d --no-deps --force-recreate "$TARGET"

# Wait for the new application to become healthy.
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

# Backup current upstream configuration.
BACKUP_FILE="$(mktemp "$DEPLOY_DIR/nginx/upstream/active-upstream.XXXXXX")"

cp "$UPSTREAM_FILE" "$BACKUP_FILE"

TEMP_UPSTREAM=""

cleanup() {
  [[ -n "$BACKUP_FILE" ]] && rm -f "$BACKUP_FILE"
  [[ -n "$TEMP_UPSTREAM" ]] && rm -f "$TEMP_UPSTREAM"
}

trap cleanup EXIT

# Rollback function.
rollback() {
  echo "ERROR: Deployment verification failed."
  echo "Rolling back traffic to $PREVIOUS..."

  # Restore previous configuration.
  if ! cp "$BACKUP_FILE" "$UPSTREAM_FILE"; then
    echo "CRITICAL: Could not restore upstream configuration."
    return 1
  fi

  # Validate configuration without requiring Nginx to be running.
  if ! compose run --rm --no-deps nginx nginx -t; then
    echo "CRITICAL: Restored Nginx configuration is invalid."
    return 1
  fi

  # Ensure Nginx is running.
  if ! compose up -d --no-deps nginx; then
    echo "CRITICAL: Could not start Nginx during rollback."
    return 1
  fi

  # Reload restored configuration.
  if ! compose exec -T nginx nginx -s reload; then
    echo "CRITICAL: Could not reload Nginx during rollback."
    return 1
  fi

  # Verify restored traffic.
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

# Ensure Nginx is running before switching traffic.
echo "Ensuring Nginx is running..."

if ! compose up -d --no-deps nginx; then
  echo "ERROR: Could not start Nginx."
  exit 1
fi

# Validate existing Nginx configuration.
if ! compose run --rm --no-deps nginx nginx -t; then
  echo "ERROR: Current Nginx configuration is invalid."
  exit 1
fi

# Write the new upstream atomically.
echo "Switching traffic from $PREVIOUS to $TARGET..."

TEMP_UPSTREAM="$(mktemp "$DEPLOY_DIR/nginx/upstream/active-upstream.XXXXXX")"

printf 'server %s:3000;\n' "$TARGET" > "$TEMP_UPSTREAM"

mv "$TEMP_UPSTREAM" "$UPSTREAM_FILE"

TEMP_UPSTREAM=""

# Validate new configuration.
if ! compose run --rm --no-deps nginx nginx -t; then
  rollback || true
  exit 1
fi

# Reload Nginx with the new upstream.
if ! compose exec -T nginx nginx -s reload; then
  rollback || true
  exit 1
fi

# Verify application through Nginx.
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

# Deployment verification failed.
if ! rollback; then
  echo "CRITICAL: Automatic rollback could not be fully verified."
fi

exit 1
```