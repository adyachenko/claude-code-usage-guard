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

# Effective settings: ENV > config file (совпадает с логикой check-usage.sh).
MODE="${USAGE_GUARD_MODE:-$(jq -r '.mode // "auto"' "$CONFIG_FILE")}"
TH="${USAGE_GUARD_BLOCK_PCT:-$(jq -r '.threshold_block_pct' "$CONFIG_FILE")}"
WARN="${USAGE_GUARD_WARN_PCT:-$(jq -r '.threshold_warn_pct' "$CONFIG_FILE")}"
FIXED_LIMIT="${USAGE_GUARD_TOKEN_LIMIT:-$(jq -r '.token_limit_5h' "$CONFIG_FILE")}"

if [[ "$MODE" == "fixed" ]]; then
  LIMIT="$FIXED_LIMIT"
else
  ALL="$("${CCU[@]}" blocks --json 2>/dev/null)"
  LIMIT="$(printf '%s' "$ALL" | jq -r '[.blocks[].totalTokens // 0] | max // 0')"
  [[ -z "$LIMIT" || "$LIMIT" == "0" ]] && LIMIT="$FIXED_LIMIT"
fi

PCT="$(LC_NUMERIC=C awk -v t="$TOTAL" -v l="$LIMIT" 'BEGIN{printf "%.1f", (t/l)*100}')"

# Kill-switch состояние.
KILL_SWITCH="${XDG_STATE_HOME:-$HOME/.local/state}/usage-guard/disabled"
if [[ "${USAGE_GUARD_DISABLE:-}" == "1" ]]; then
  STATE="DISABLED (env USAGE_GUARD_DISABLE=1)"
elif [[ -f "$KILL_SWITCH" ]]; then
  STATE="DISABLED (флаг: $KILL_SWITCH)"
else
  STATE="enabled"
fi

# Активные env-override.
OVERRIDES=""
for v in USAGE_GUARD_MODE USAGE_GUARD_BLOCK_PCT USAGE_GUARD_WARN_PCT \
         USAGE_GUARD_TOKEN_LIMIT USAGE_GUARD_THROTTLE USAGE_GUARD_BUFFER_MIN \
         USAGE_GUARD_RESUME_PROMPT; do
  val="${!v:-}"
  [[ -n "$val" ]] && OVERRIDES+="  $v=$val"$'\n'
done

cat <<EOF
usage-guard ($STATE)
============================================
5-часовое окно: использовано $TOTAL из $LIMIT токенов (${PCT}%)
Окно закрывается: $END
Режим лимита:   $MODE
Пороги:         warn=${WARN}%  block=${TH}%
Config file:    $CONFIG_FILE
EOF

if [[ -n "$OVERRIDES" ]]; then
  echo ""
  echo "Активные ENV-override:"
  printf '%s' "$OVERRIDES"
fi
