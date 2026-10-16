#!/usr/bin/env bash
# Open a Cloudflare quick tunnel to the local ladder and publish that URL
# in this git repo (GitHub Pages). When cloudflared exits, start another
# tunnel and push the new URL. Do not put passwords or API keys in this repo.
set -euo pipefail

PAGE_DIR="${PAGE_DIR:-$(cd "$(dirname "$0")" && pwd)}"
PAGE_ORIGIN="${PAGE_ORIGIN:-http://127.0.0.1:8765}"
WATCH_ORIGIN="${WATCH_ORIGIN:-http://127.0.0.1:8766}"
WATCH_FILE="${WATCH_FILE:-}"
LOG="${LOG:-$PAGE_DIR/rotations.log}"

need() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "missing command: $1" >&2
    exit 1
  }
}
need cloudflared
need git
need python3

one_tunnel() {
  local origin="$1"
  local log="$2"
  cloudflared tunnel --url "$origin" --no-autoupdate >"$log" 2>&1 &
  echo $!
}

wait_url() {
  local log="$1"
  local i url
  for i in $(seq 1 90); do
    url="$(grep -oE 'https://[a-zA-Z0-9-]+\.trycloudflare\.com' "$log" | head -1 || true)"
    if [[ -n "$url" ]]; then
      echo "$url"
      return 0
    fi
    sleep 1
  done
  return 1
}

publish() {
  local page_url="$1"
  local watch_url="$2"
  UPDATED="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  PAGE_URL="$page_url" WATCH_URL="$watch_url" UPDATED="$UPDATED" PAGE_DIR="$PAGE_DIR" python3 - <<'PY'
import json, os
from pathlib import Path
path = Path(os.environ["PAGE_DIR"]) / "tunnel.json"
path.write_text(json.dumps({
    "url": os.environ["PAGE_URL"],
    "watch": os.environ["WATCH_URL"],
    "updated": os.environ["UPDATED"],
}, indent=2) + "\n")
PY
  if [[ -n "$WATCH_FILE" ]]; then
    mkdir -p "$(dirname "$WATCH_FILE")"
    printf '%s\n' "$watch_url" >"$WATCH_FILE"
  fi
  {
    echo "$UPDATED page $page_url"
    echo "$UPDATED watch $watch_url"
  } >>"$LOG"
  git -C "$PAGE_DIR" add tunnel.json
  git -C "$PAGE_DIR" diff --cached --quiet && return 0
  git -C "$PAGE_DIR" commit -m "Point the ladder at a new tunnel"
  git -C "$PAGE_DIR" push
}

stop() {
  local pid="$1"
  if kill -0 "$pid" 2>/dev/null; then
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  fi
}

while true; do
  page_log="$(mktemp)"
  watch_log="$(mktemp)"
  page_pid="$(one_tunnel "$PAGE_ORIGIN" "$page_log")"
  watch_pid="$(one_tunnel "$WATCH_ORIGIN" "$watch_log")"
  page_url=""
  watch_url=""
  if page_url="$(wait_url "$page_log")" && watch_url="$(wait_url "$watch_log")"; then
    publish "$page_url" "$watch_url"
    # Stay up until either tunnel process exits, then replace both.
    while kill -0 "$page_pid" 2>/dev/null && kill -0 "$watch_pid" 2>/dev/null; do
      sleep 15
    done
  fi
  stop "$page_pid"
  stop "$watch_pid"
  rm -f "$page_log" "$watch_log"
  sleep 3
done
