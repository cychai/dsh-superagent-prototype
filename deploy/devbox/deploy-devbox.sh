#!/bin/sh
set -eu

repo_dir="${DSH_SUPERAGENT_REPO_DIR:-/home/chaichunyan/dsh-superagent/superagent-src}"
deploy_dir="${DSH_SUPERAGENT_DEPLOY_DIR:-/home/chaichunyan/dsh-superagent}"
branch="${DSH_SUPERAGENT_BRANCH:-main}"
health_timeout="${DSH_SUPERAGENT_HEALTH_TIMEOUT:-180}"
lock_file="${DSH_SUPERAGENT_UPDATE_LOCK:-/tmp/dsh-superagent-update.lock}"
fetch_timeout="${DSH_SUPERAGENT_FETCH_TIMEOUT:-120}"

exec 9>"$lock_file"
if ! flock -n 9; then
  echo "Another dsh-superagent update is running; skipping."
  exit 0
fi

git -C "$repo_dir" diff --quiet
git -C "$repo_dir" diff --cached --quiet
if [ -n "$(git -C "$repo_dir" status --porcelain --untracked-files=normal -- . ':(exclude).source-commit')" ]; then
  echo "Refusing to deploy a dirty checkout: $repo_dir" >&2
  exit 1
fi

if ! timeout "$fetch_timeout" git -C "$repo_dir" fetch --prune origin "$branch"; then
  echo "Unable to fetch origin/$branch within ${fetch_timeout}s; leaving the running deployment unchanged." >&2
  exit 1
fi
current_commit="$(git -C "$repo_dir" rev-parse HEAD)"
target_commit="$(git -C "$repo_dir" rev-parse "origin/$branch")"

if [ "$current_commit" = "$target_commit" ]; then
  echo "Already deployed $target_commit."
  exit 0
fi

if [ "$(git -C "$repo_dir" symbolic-ref --quiet --short HEAD || true)" != "$branch" ]; then
  echo "Refusing to deploy while checkout is not on $branch." >&2
  exit 1
fi

if ! git -C "$repo_dir" merge-base --is-ancestor "$current_commit" "$target_commit"; then
  echo "Refusing non-fast-forward deployment: $current_commit -> $target_commit" >&2
  exit 1
fi

previous_compose="$(mktemp)"
previous_source_commit="$(cat "$repo_dir/.source-commit" 2>/dev/null || printf '%s' "$current_commit")"
trap 'rm -f "$previous_compose"' EXIT INT TERM
cp "$deploy_dir/compose.yml" "$previous_compose"

printf '%s\n' "$target_commit" >"$repo_dir/.source-commit"

short_commit="$(printf '%s' "$target_commit" | cut -c1-7)"
candidate_image="local/dsh-superagent:0.1.0-$short_commit"
current_image="$(sudo -n docker inspect dsh-superagent --format '{{.Config.Image}}' 2>/dev/null || true)"

if [ -n "$current_image" ]; then
  sudo -n docker tag "$current_image" local/dsh-superagent:rollback
fi

python3 - "$deploy_dir/compose.yml" "$candidate_image" "$target_commit" <<'PY'
from pathlib import Path
import re
import sys

path = Path(sys.argv[1])
image = sys.argv[2]
commit = sys.argv[3]
text = path.read_text()
text, image_count = re.subn(r'(?m)^(\s*image:\s*)local/dsh-superagent:[^\s]+$', rf'\g<1>{image}', text, count=1)
text, commit_count = re.subn(r'(?m)^(\s*SUPERAGENT_COMMIT:\s*)\S+$', rf'\g<1>{commit}', text, count=1)
if image_count != 1 or commit_count != 1:
    raise SystemExit('compose.yml does not contain one expected image and SUPERAGENT_COMMIT field')
path.write_text(text)
PY

rollback() {
  echo "Candidate failed; restoring $current_commit." >&2
  cp "$previous_compose" "$deploy_dir/compose.yml"
  printf '%s\n' "$previous_source_commit" >"$repo_dir/.source-commit"
  if [ -n "$current_image" ]; then
    sudo -n docker compose -f "$deploy_dir/compose.yml" up -d --force-recreate
  fi
}

if ! sudo -n docker compose -f "$deploy_dir/compose.yml" build dsh-superagent; then
  rollback
  exit 1
fi

if ! sudo -n docker compose -f "$deploy_dir/compose.yml" up -d --force-recreate; then
  rollback
  exit 1
fi

deadline=$(( $(date +%s) + health_timeout ))
while [ "$(date +%s)" -lt "$deadline" ]; do
  health="$(sudo -n docker inspect dsh-superagent --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' 2>/dev/null || true)"
  if [ "$health" = healthy ]; then
    git -C "$repo_dir" merge --ff-only "origin/$branch"
    printf '%s\n' "$target_commit" >"$repo_dir/.source-commit"
    printf '%s\n' "$target_commit" >"$deploy_dir/.deployed-commit"
    echo "Deployed $target_commit as $candidate_image."
    exit 0
  fi
  if [ "$health" = unhealthy ] || [ "$health" = exited ] || [ "$health" = dead ]; then
    break
  fi
  sleep 5
done

rollback
exit 1
