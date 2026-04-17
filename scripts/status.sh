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
PROJECTED_TOKENS="$(printf '%s' "$BLOCK" | jq -r '.projection.totalTokens // .totalTokens')"
REMAIN_MIN="$(printf '%s' "$BLOCK" | jq -r '.projection.remainingMinutes // 0')"
BURN_RATE="$(printf '%s' "$BLOCK" | jq -r '.burnRate.tokensPerMinute // 0')"
CCU_LIMIT="$(printf '%s' "$BLOCK" | jq -r '.tokenLimitStatus.limit // 0')"
COST_NOW="$(printf '%s' "$BLOCK" | jq -r '.costUSD // 0')"
COST_PROJ="$(printf '%s' "$BLOCK" | jq -r '.projection.totalCost // .costUSD // 0')"

# Effective settings.
MODE="${USAGE_GUARD_MODE:-${CLAUDE_PLUGIN_OPTION_MODE:-$(jq -r '.mode // "auto"' "$CONFIG_FILE")}}"
TH="${USAGE_GUARD_BLOCK_PCT:-${CLAUDE_PLUGIN_OPTION_BLOCK_PCT:-$(jq -r '.threshold_block_pct' "$CONFIG_FILE")}}"
WARN="${USAGE_GUARD_WARN_PCT:-${CLAUDE_PLUGIN_OPTION_WARN_PCT:-$(jq -r '.threshold_warn_pct' "$CONFIG_FILE")}}"
FIXED_TOKEN_LIMIT="${USAGE_GUARD_TOKEN_LIMIT:-${CLAUDE_PLUGIN_OPTION_TOKEN_LIMIT:-$(jq -r '.token_limit_5h' "$CONFIG_FILE")}}"
COST_LIMIT="${USAGE_GUARD_COST_LIMIT:-${CLAUDE_PLUGIN_OPTION_COST_LIMIT:-$(jq -r '.cost_limit_5h_usd // 0' "$CONFIG_FILE")}}"
BLOCK_ON="${USAGE_GUARD_BLOCK_ON:-${CLAUDE_PLUGIN_OPTION_BLOCK_ON:-$(jq -r '.block_on // "projected"' "$CONFIG_FILE")}}"
CAL_AT="$(jq -r '.calibration.at // empty' "$CONFIG_FILE" 2>/dev/null)"
CAL_PCT="$(jq -r '.calibration.anthropic_pct // empty' "$CONFIG_FILE" 2>/dev/null)"

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

case "$MODE" in
  cost)
    LIMIT_SOURCE="cost (calibrated)"
    LIMIT_DISPLAY="\$$(LC_NUMERIC=C awk -v v="$COST_LIMIT" 'BEGIN{printf "%.2f", v}')"
    PCT_CURRENT="$(LC_NUMERIC=C awk -v t="$COST_NOW"  -v l="$COST_LIMIT" 'BEGIN{if(l>0) printf "%.1f", (t/l)*100; else print "?"}')"
    PCT_PROJ="$(   LC_NUMERIC=C awk -v t="$COST_PROJ" -v l="$COST_LIMIT" 'BEGIN{if(l>0) printf "%.1f", (t/l)*100; else print "?"}')"
    CUR_DISPLAY="\$$(LC_NUMERIC=C awk -v v="$COST_NOW"  'BEGIN{printf "%.2f", v}')"
    PROJ_DISPLAY="\$$(LC_NUMERIC=C awk -v v="$COST_PROJ" 'BEGIN{printf "%.2f", v}')"
    ;;
  fixed)
    LIMIT_SOURCE="fixed (tokens)"
    LIMIT_DISPLAY="$FIXED_TOKEN_LIMIT токенов"
    PCT_CURRENT="$(LC_NUMERIC=C awk -v t="$TOTAL"            -v l="$FIXED_TOKEN_LIMIT" 'BEGIN{printf "%.1f", (t/l)*100}')"
    PCT_PROJ="$(   LC_NUMERIC=C awk -v t="$PROJECTED_TOKENS" -v l="$FIXED_TOKEN_LIMIT" 'BEGIN{printf "%.1f", (t/l)*100}')"
    CUR_DISPLAY="$TOTAL токенов"
    PROJ_DISPLAY="$PROJECTED_TOKENS токенов"
    ;;
  *)
    LIMIT_SOURCE="auto — ccusage max-of-history (НЕ реальный лимит подписки)"
    LIMIT_DISPLAY="$CCU_LIMIT токенов"
    PCT_CURRENT="$(LC_NUMERIC=C awk -v t="$TOTAL"            -v l="$CCU_LIMIT" 'BEGIN{if(l>0) printf "%.1f", (t/l)*100; else print "?"}')"
    PCT_PROJ="$(   LC_NUMERIC=C awk -v t="$PROJECTED_TOKENS" -v l="$CCU_LIMIT" 'BEGIN{if(l>0) printf "%.1f", (t/l)*100; else print "?"}')"
    CUR_DISPLAY="$TOTAL токенов"
    PROJ_DISPLAY="$PROJECTED_TOKENS токенов"
    ;;
esac

cat <<EOF
usage-guard ($STATE)
============================================
Текущее:    $CUR_DISPLAY   (${PCT_CURRENT}% от лимита)
Прогноз:    $PROJ_DISPLAY   (${PCT_PROJ}% от лимита)
Лимит:      $LIMIT_DISPLAY   [$LIMIT_SOURCE]
Окно до:    $END   (осталось ${REMAIN_MIN} мин)
Burn rate:  ${BURN_FMT} токенов/мин

Блокировка: метрика=$BLOCK_ON   warn=${WARN}%   block=${TH}%
Режим:      $MODE
Config:     $CONFIG_FILE
EOF

if [[ -n "$CAL_AT" ]]; then
  echo "Калибровка: ${CAL_PCT}% по Anthropic UI от ${CAL_AT}"
fi

if [[ "$MODE" == "auto" ]]; then
  cat <<'EOF'

⚠ Режим auto считает лимитом максимум из истории ccusage — это не реальный
  лимит подписки. Рекомендуется откалиброваться по Anthropic UI:

    1. Открой claude.ai → Settings → Usage и посмотри % 5h-окна.
    2. Запусти /usage-guard:calibrate <pct>   (подставь число).

  Плагин переключится в mode=cost (лимит в $USD, учитывает разные модели
  Opus/Sonnet/Haiku автоматически).
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
