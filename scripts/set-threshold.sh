#!/usr/bin/env bash
# Установить threshold_block_pct в пользовательском конфиге usage-guard.
# Usage: set-threshold.sh <pct>  (целое число 1..99)
set -eu

PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
CONFIG_USER="${XDG_CONFIG_HOME:-$HOME/.config}/usage-guard/limits.json"
CONFIG_DEFAULT="${PLUGIN_ROOT}/config/limits.json"

PCT="${1:-}"
if [[ -z "$PCT" ]]; then
  echo "usage: /usage-guard:set-threshold <pct>   (целое 1..99)" >&2
  exit 1
fi
if ! [[ "$PCT" =~ ^[0-9]+$ ]] || (( PCT < 1 || PCT > 99 )); then
  echo "invalid threshold: '$PCT' (нужно целое число 1..99)" >&2
  exit 1
fi

mkdir -p "$(dirname "$CONFIG_USER")"
if [[ ! -f "$CONFIG_USER" ]]; then
  cp "$CONFIG_DEFAULT" "$CONFIG_USER"
fi

tmp="$(mktemp)"
jq --argjson pct "$PCT" '.threshold_block_pct = $pct' "$CONFIG_USER" >"$tmp"
mv "$tmp" "$CONFIG_USER"

echo "✓ threshold_block_pct = ${PCT}%"
echo "  config: $CONFIG_USER"
echo ""
echo "Альтернатива без правки файла (разовый override на сессию):"
echo "  USAGE_GUARD_BLOCK_PCT=${PCT} claude"
