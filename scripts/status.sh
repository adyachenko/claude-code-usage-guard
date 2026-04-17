#!/usr/bin/env bash
# /usage-guard:status — текущее потребление 5-часового окна, прогноз, лимит, пороги.
set -u

PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
CONFIG_USER="${XDG_CONFIG_HOME:-$HOME/.config}/usage-guard/limits.json"
CONFIG_DEFAULT="${PLUGIN_ROOT}/config/limits.json"
CONFIG_FILE="$CONFIG_DEFAULT"; [[ -r "$CONFIG_USER" ]] && CONFIG_FILE="$CONFIG_USER"

have() { command -v "$1" >/dev/null 2>&1; }

if ! have jq; then echo "jq не установлен — установи: brew install jq"; exit 0; fi

if   have ccusage; then CCU=(ccusage)
elif have bunx;    then CCU=(bunx ccusage@latest)
elif have npx;     then CCU=(npx -y ccusage@latest)
else echo "ccusage недоступен (нет ccusage/bunx/npx в PATH)"; exit 0; fi

OUT="$("${CCU[@]}" blocks --json --active --token-limit max 2>/dev/null)"
BLOCK="$(printf '%s' "$OUT" | jq -c '.blocks[] | select(.isActive==true)' | head -n1)"

if [[ -z "$BLOCK" ]]; then
  echo "usage-guard: активного 5-часового блока нет — окно пустое или ccusage без данных."
  exit 0
fi

TOTAL="$(printf '%s' "$BLOCK" | jq -r '.totalTokens')"
END="$(printf '%s' "$BLOCK" | jq -r '.endTime')"
PROJECTED="$(printf '%s' "$BLOCK" | jq -r '.projection.totalTokens // .totalTokens')"
REMAIN_MIN="$(printf '%s' "$BLOCK" | jq -r '.projection.remainingMinutes // 0')"
BURN_RATE="$(printf '%s' "$BLOCK" | jq -r '.burnRate.tokensPerMinute // 0')"
CCU_LIMIT="$(printf '%s' "$BLOCK" | jq -r '.tokenLimitStatus.limit // 0')"

# Effective settings (ENV > userConfig > config file).
MODE="${USAGE_GUARD_MODE:-${CLAUDE_PLUGIN_OPTION_MODE:-$(jq -r '.mode // "auto"' "$CONFIG_FILE")}}"
TH="${USAGE_GUARD_BLOCK_PCT:-${CLAUDE_PLUGIN_OPTION_BLOCK_PCT:-$(jq -r '.threshold_block_pct' "$CONFIG_FILE")}}"
WARN="${USAGE_GUARD_WARN_PCT:-${CLAUDE_PLUGIN_OPTION_WARN_PCT:-$(jq -r '.threshold_warn_pct' "$CONFIG_FILE")}}"
FIXED_LIMIT="${USAGE_GUARD_TOKEN_LIMIT:-${CLAUDE_PLUGIN_OPTION_TOKEN_LIMIT:-$(jq -r '.token_limit_5h' "$CONFIG_FILE")}}"
BLOCK_ON="${USAGE_GUARD_BLOCK_ON:-${CLAUDE_PLUGIN_OPTION_BLOCK_ON:-$(jq -r '.block_on // "projected"' "$CONFIG_FILE")}}"

if [[ "$MODE" == "fixed" && -n "$FIXED_LIMIT" && "$FIXED_LIMIT" != "0" ]]; then
  LIMIT="$FIXED_LIMIT"
  LIMIT_SOURCE="fixed"
else
  LIMIT="$CCU_LIMIT"
  [[ -z "$LIMIT" || "$LIMIT" == "0" ]] && LIMIT="$FIXED_LIMIT"
  LIMIT_SOURCE="auto (ccusage max)"
fi

PCT_CURRENT="$(LC_NUMERIC=C awk -v t="$TOTAL" -v l="$LIMIT" 'BEGIN{printf "%.1f", (t/l)*100}')"
PCT_PROJ="$(LC_NUMERIC=C awk -v t="$PROJECTED" -v l="$LIMIT" 'BEGIN{printf "%.1f", (t/l)*100}')"
BURN_FMT="$(LC_NUMERIC=C awk -v r="$BURN_RATE" 'BEGIN{printf "%.0f", r}')"

# Kill-switch.
KILL_SWITCH="${XDG_STATE_HOME:-$HOME/.local/state}/usage-guard/disabled"
if [[ "${USAGE_GUARD_DISABLE:-}" == "1" ]]; then
  STATE="DISABLED (env)"
elif [[ -f "$KILL_SWITCH" ]]; then
  STATE="DISABLED (flag: $KILL_SWITCH)"
else
  STATE="enabled"
fi

cat <<EOF
usage-guard ($STATE)
============================================
Текущее:    $TOTAL токенов   (${PCT_CURRENT}% от лимита)
Прогноз:    $PROJECTED токенов   (${PCT_PROJ}% от лимита)
Лимит:      $LIMIT токенов   [$LIMIT_SOURCE]
Окно до:    $END   (осталось ${REMAIN_MIN} мин)
Burn rate:  ${BURN_FMT} токенов/мин

Блокировка: метрика=$BLOCK_ON   warn=${WARN}%   block=${TH}%
Режим:      $MODE
Config:     $CONFIG_FILE
EOF

if [[ "$LIMIT_SOURCE" == auto* ]]; then
  cat <<EOF

⚠ Режим auto считает лимитом максимум из истории — это НЕ реальный лимит
  подписки Anthropic. Для точного %: посмотри реальный лимит в Anthropic UI
  (claude.ai → Settings → Usage) и зафиксируй его:
    /usage-guard:set-limit <tokens>       # переключает в fixed с твоим значением
EOF
fi

# Активные ENV-override.
OVERRIDES=""
for v in USAGE_GUARD_MODE USAGE_GUARD_BLOCK_PCT USAGE_GUARD_WARN_PCT \
         USAGE_GUARD_TOKEN_LIMIT USAGE_GUARD_THROTTLE USAGE_GUARD_BUFFER_MIN \
         USAGE_GUARD_RESUME_PROMPT USAGE_GUARD_BLOCK_ON \
         CLAUDE_PLUGIN_OPTION_MODE CLAUDE_PLUGIN_OPTION_BLOCK_PCT \
         CLAUDE_PLUGIN_OPTION_WARN_PCT CLAUDE_PLUGIN_OPTION_TOKEN_LIMIT \
         CLAUDE_PLUGIN_OPTION_THROTTLE_SECONDS CLAUDE_PLUGIN_OPTION_RESUME_PROMPT \
         CLAUDE_PLUGIN_OPTION_BLOCK_ON; do
  val="${!v:-}"
  [[ -n "$val" ]] && OVERRIDES+="  $v=$val"$'\n'
done
if [[ -n "$OVERRIDES" ]]; then
  echo ""
  echo "Активные ENV-override:"
  printf '%s' "$OVERRIDES"
fi
