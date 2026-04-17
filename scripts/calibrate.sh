#!/usr/bin/env bash
# Калибровка лимита против реального процента из Anthropic UI.
#
# Usage: /usage-guard:calibrate <anthropic_pct>
#
# Что делает:
#   1. Читает текущий active block из ccusage (totalTokens, costUSD).
#   2. Считает лимит: limit = current / (pct / 100).
#   3. Пишет cost_limit_5h_usd и mode=cost в пользовательский конфиг.
#
# Почему cost, а не токены:
#   разные модели (Opus/Sonnet/Haiku) расходуют 5h-квоту неодинаково.
#   ccusage знает прайсинг моделей и считает $ — это точный прокси к тому,
#   как Anthropic внутри квотирует «работу». Сырые токены смещают оценку
#   при смене model-mix.
set -eu

PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
CONFIG_USER="${XDG_CONFIG_HOME:-$HOME/.config}/usage-guard/limits.json"
CONFIG_DEFAULT="${PLUGIN_ROOT}/config/limits.json"

PCT="${1:-}"
if [[ -z "$PCT" ]]; then
  cat >&2 <<'EOF'
usage: /usage-guard:calibrate <anthropic_pct>

Шаги:
  1. Открой claude.ai → Settings → Usage (или страницу лимитов в CLI).
  2. Найди "5-hour session" usage в процентах.
  3. Запусти: /usage-guard:calibrate 79   (подставь свой процент)

Плагин зафиксирует текущий $ cost как 79% твоего лимита и переключится
в режим cost. Перекалибровать можно в любой момент.
EOF
  exit 1
fi

if ! LC_NUMERIC=C awk -v p="$PCT" 'BEGIN{exit !(p+0>0 && p+0<100)}'; then
  echo "invalid percent: '$PCT' (нужно число > 0 и < 100)" >&2
  exit 1
fi

have() { command -v "$1" >/dev/null 2>&1; }
if   have ccusage; then CCU=(ccusage)
elif have bunx;    then CCU=(bunx ccusage@latest)
elif have npx;     then CCU=(npx -y ccusage@latest)
else echo "ccusage недоступен" >&2; exit 1; fi

OUT="$("${CCU[@]}" blocks --json --active --token-limit max 2>/dev/null)"
BLOCK="$(printf '%s' "$OUT" | jq -c '.blocks[] | select(.isActive==true)' | head -n1)"
if [[ -z "$BLOCK" ]]; then
  echo "no active 5h block — запусти калибровку позже, когда появятся данные" >&2
  exit 1
fi

COST_NOW="$(printf '%s' "$BLOCK" | jq -r '.costUSD // 0')"
TOKENS_NOW="$(printf '%s' "$BLOCK" | jq -r '.totalTokens // 0')"

if ! LC_NUMERIC=C awk -v c="$COST_NOW" 'BEGIN{exit !(c+0>0)}'; then
  echo "текущий cost=0 — запусти калибровку после накопления usage в окне" >&2
  exit 1
fi

# limit_usd = current_cost / (pct / 100)
COST_LIMIT="$(LC_NUMERIC=C awk -v c="$COST_NOW" -v p="$PCT" 'BEGIN{printf "%.4f", c*100/p}')"
# derived token-limit для справки (не используется при mode=cost).
TOKEN_LIMIT="$(LC_NUMERIC=C awk -v t="$TOKENS_NOW" -v p="$PCT" 'BEGIN{printf "%d", t*100/p}')"

mkdir -p "$(dirname "$CONFIG_USER")"
[[ -f "$CONFIG_USER" ]] || cp "$CONFIG_DEFAULT" "$CONFIG_USER"

tmp="$(mktemp)"
jq --argjson cost "$COST_LIMIT" \
   --argjson tok  "$TOKEN_LIMIT" \
   --arg     at   "$(date -u +%FT%TZ)" \
   --arg     src_pct "$PCT" \
   '.mode = "cost"
    | .cost_limit_5h_usd = $cost
    | .token_limit_5h    = $tok
    | .calibration       = {at:$at, anthropic_pct:($src_pct|tonumber)}' \
   "$CONFIG_USER" >"$tmp"
mv "$tmp" "$CONFIG_USER"

cat <<EOF
✓ Калибровка сохранена

  Anthropic UI:   ${PCT}%
  Текущий cost:   \$${COST_NOW}
  Текущие токены: ${TOKENS_NOW}

  → 100% 5h-окна ≈ \$${COST_LIMIT}   (=${TOKEN_LIMIT} токенов при том же model-mix)

  mode:                cost   (лимит в долларах, учитывает Opus/Sonnet/Haiku)
  cost_limit_5h_usd:   ${COST_LIMIT}
  config:              $CONFIG_USER

Проверить: /usage-guard:status
EOF
