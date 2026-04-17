#!/usr/bin/env bash
# Установить жёсткий token-лимит на 5-часовое окно и переключить в mode=fixed.
# Usage: set-limit.sh <tokens>     — число, можно с суффиксом k/m/b (44m, 220M, 1b)
set -eu

PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
CONFIG_USER="${XDG_CONFIG_HOME:-$HOME/.config}/usage-guard/limits.json"
CONFIG_DEFAULT="${PLUGIN_ROOT}/config/limits.json"

RAW="${1:-}"
if [[ -z "$RAW" ]]; then
  cat >&2 <<EOF
usage: /usage-guard:set-limit <tokens>

  Примеры:
    /usage-guard:set-limit 44000000      # ~Pro (5h)
    /usage-guard:set-limit 220m          # ~Max 5x
    /usage-guard:set-limit 880m          # ~Max 20x
    /usage-guard:set-limit 1.1b          # кастом

  Реальный лимит подмотай из Anthropic UI → Settings → Usage.
  После установки режим переключается в "fixed".
EOF
  exit 1
fi

# Парсим суффиксы (k/m/b, регистронезависимо).
NUM="${RAW%[kKmMgGbB]}"
SFX="${RAW:${#NUM}}"
if ! [[ "$NUM" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
  echo "invalid number: '$RAW' (нужно число, опционально с суффиксом k/m/b)" >&2
  exit 1
fi

SFX_LOWER="$(printf '%s' "$SFX" | tr '[:upper:]' '[:lower:]')"
case "$SFX_LOWER" in
  "")  MULT=1 ;;
  k)   MULT=1000 ;;
  m)   MULT=1000000 ;;
  g|b) MULT=1000000000 ;;
  *)   echo "unknown suffix: '$SFX'" >&2; exit 1 ;;
esac

TOKENS="$(LC_NUMERIC=C awk -v n="$NUM" -v m="$MULT" 'BEGIN{printf "%d", n*m}')"

if (( TOKENS < 1000 )); then
  echo "подозрительно маленькое значение ($TOKENS токенов) — проверь ввод" >&2
  exit 1
fi

mkdir -p "$(dirname "$CONFIG_USER")"
[[ -f "$CONFIG_USER" ]] || cp "$CONFIG_DEFAULT" "$CONFIG_USER"

tmp="$(mktemp)"
jq --argjson t "$TOKENS" '.mode = "fixed" | .token_limit_5h = $t' "$CONFIG_USER" >"$tmp"
mv "$tmp" "$CONFIG_USER"

HUMAN="$(LC_NUMERIC=C awk -v t="$TOKENS" 'BEGIN{
  if (t >= 1e9) printf "%.2fB", t/1e9
  else if (t >= 1e6) printf "%.1fM", t/1e6
  else if (t >= 1e3) printf "%.0fk", t/1e3
  else printf "%d", t
}')"

echo "✓ mode=fixed, token_limit_5h=${TOKENS} (${HUMAN})"
echo "  config: $CONFIG_USER"
echo ""
echo "Проверить: /usage-guard:status"
