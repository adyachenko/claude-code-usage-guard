#!/usr/bin/env bash
# /usage-guard:status — показывает текущее потребление и настройки порогов.
set -u

PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
CONFIG_USER="${XDG_CONFIG_HOME:-$HOME/.config}/usage-guard/limits.json"
CONFIG_DEFAULT="${PLUGIN_ROOT}/config/limits.json"
CONFIG_FILE="$CONFIG_DEFAULT"; [[ -r "$CONFIG_USER" ]] && CONFIG_FILE="$CONFIG_USER"

have() { command -v "$1" >/dev/null 2>&1; }

if ! have jq; then echo "jq не установлен — установи: brew install jq"; exit 0; fi

if have ccusage; then CCU=(ccusage)
elif have bunx; then CCU=(bunx ccusage@latest)
elif have npx;  then CCU=(npx -y ccusage@latest)
else echo "ccusage недоступен (нет ccusage/bunx/npx в PATH)"; exit 0; fi

OUT="$("${CCU[@]}" blocks --json --active 2>/dev/null)"
BLOCK="$(printf '%s' "$OUT" | jq -c '.blocks[] | select(.isActive==true)' | head -n1)"

if [[ -z "$BLOCK" ]]; then
  echo "usage-guard: активного 5-часового блока нет — либо окно пустое, либо ccusage без данных."
  exit 0
fi

TOTAL="$(printf '%s' "$BLOCK" | jq -r '.totalTokens')"
END="$(printf '%s' "$BLOCK" | jq -r '.endTime')"
MODE="$(jq -r '.mode // "auto"' "$CONFIG_FILE")"
TH="$(jq -r '.threshold_block_pct' "$CONFIG_FILE")"
WARN="$(jq -r '.threshold_warn_pct' "$CONFIG_FILE")"

if [[ "$MODE" == "fixed" ]]; then
  LIMIT="$(jq -r '.token_limit_5h' "$CONFIG_FILE")"
else
  ALL="$("${CCU[@]}" blocks --json 2>/dev/null)"
  LIMIT="$(printf '%s' "$ALL" | jq -r '[.blocks[].totalTokens // 0] | max // 0')"
  [[ -z "$LIMIT" || "$LIMIT" == "0" ]] && LIMIT="$(jq -r '.token_limit_5h' "$CONFIG_FILE")"
fi

PCT="$(LC_NUMERIC=C awk -v t="$TOTAL" -v l="$LIMIT" 'BEGIN{printf "%.1f", (t/l)*100}')"

cat <<EOF
usage-guard
===========
5-часовое окно: использовано $TOTAL из $LIMIT токенов (${PCT}%)
Окно закрывается: $END
Режим лимита: $MODE
Пороги: warn=${WARN}%  block=${TH}%
Config: $CONFIG_FILE
EOF
