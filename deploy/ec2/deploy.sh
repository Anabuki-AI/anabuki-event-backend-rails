#!/usr/bin/env bash
set -Eeuo pipefail

: "${RELEASE_SHA:?RELEASE_SHA is required}"
: "${APP_ROOT:=/opt/anabuki-event}"
: "${ARCHIVE_PATH:?ARCHIVE_PATH is required}"

release_dir="$APP_ROOT/releases/$RELEASE_SHA"
current_link="$APP_ROOT/current"
shared_dir="$APP_ROOT/shared"
compose_file="$release_dir/deploy/ec2/docker-compose.production.yml"

if [[ ! -f "$ARCHIVE_PATH" ]]; then
  echo "release archive is missing" >&2
  exit 1
fi
if [[ ! -f "$shared_dir/.env.production" || ! -f "$shared_dir/.cloudflared.env" ]]; then
  echo "required deployment environment files are missing" >&2
  exit 1
fi

mkdir -p "$release_dir"
tar --extract --gzip --file "$ARCHIVE_PATH" --directory "$release_dir"
ln -sfn "$shared_dir/.env.production" "$release_dir/deploy/ec2/.env.production"
ln -sfn "$shared_dir/.cloudflared.env" "$release_dir/deploy/ec2/.cloudflared.env"
chmod 700 "$release_dir/deploy/ec2/deploy.sh" 2>/dev/null || true

old_target=""
if [[ -L "$current_link" ]]; then
  old_target=$(readlink -f "$current_link") || true
fi
ln -sfn "$release_dir" "$current_link"

compose=(docker compose --project-name anabuki-event --file "$compose_file")
rollback() {
  status=$?
  if (( status != 0 )) && [[ -n "$old_target" && -f "$old_target/deploy/ec2/docker-compose.production.yml" ]]; then
    echo "deployment failed; restoring previous release" >&2
    ln -sfn "$old_target" "$current_link"
    docker compose --project-name anabuki-event --file "$old_target/deploy/ec2/docker-compose.production.yml" up -d --remove-orphans || true
  fi
  exit "$status"
}
trap rollback EXIT

"${compose[@]}" config --quiet
"${compose[@]}" build --pull api
"${compose[@]}" up -d --remove-orphans api worker cloudflared
"${compose[@]}" ps

trap - EXIT
rm -f "$ARCHIVE_PATH"
find "$APP_ROOT/releases" -mindepth 1 -maxdepth 1 -type d -printf '%T@ %p\n' \
  | sort -nr | tail -n +6 | cut -d' ' -f2- | xargs -r rm -rf
