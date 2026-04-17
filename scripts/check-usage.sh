#!/usr/bin/env bash
# usage-guard PreToolUse hook.
# Читает stdin (hook payload), решает блокировать вызов или пропустить.
# Источник данных о потреблении — ccusage (https://github.com/ryoppippi/ccusage).
# Stdout: молча (exit 0 = approve).
# Stderr + exit 2: блокировка с сообщением агенту.
set -u

PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/usage-guard"
CONFIG_USER="${XDG_CONFIG_HOME:-$HOME/.config}/usage-guard/limits.json"
CONFIG_DEFAULT="${PLUGIN_ROOT}/config/limits.json"

mkdir -p "$STATE_DIR"
LOCK="$STATE_DIR/last-check"
LOG="$STATE_DIR/hook.log"
KILL_SWITCH="$STATE_DIR/disabled"

log() { printf '[%s] %s\n' "$(date -u +%FT%TZ)" "$*" >>"$LOG"; }

# --- Kill switches --------------------------------------------------------
# Runtime-переключатели — проверяются до всего остального.
#   USAGE_GUARD_DISABLE=1  или  флаг-файл $STATE_DIR/disabled
#   → хук сразу пропускает вызов.
if [[ "${USAGE_GUARD_DISABLE:-}" == "1" || -f "$KILL_SWITCH" ]]; then
  exit 0
fi

# --- Dependencies ---------------------------------------------------------

have() { command -v "$1" >/dev/null 2>&1; }

if ! have jq; then
  log "jq not found — skipping check"
  exit 0
fi

# ccusage может запускаться через bunx/npx/глобально.
if have ccusage; then
  CCUSAGE_CMD=(ccusage)
elif have bunx; then
  CCUSAGE_CMD=(bunx ccusage@latest)
elif have npx; then
  CCUSAGE_CMD=(npx -y ccusage@latest)
else
  log "ccusage not available (no ccusage/bunx/npx in PATH) — skipping"
  exit 0
fi

# --- Input ----------------------------------------------------------------

PAYLOAD="$(cat || true)"
TOOL_NAME="$(printf '%s' "$PAYLOAD" | jq -r '.tool_name // ""' 2>/dev/null || echo "")"

# --- Config ---------------------------------------------------------------

if [[ -r "$CONFIG_USER" ]]; then
  CONFIG_FILE="$CONFIG_USER"
else
  CONFIG_FILE="$CONFIG_DEFAULT"
fi

cfg() { jq -r "$1 // empty" "$CONFIG_FILE" 2>/dev/null; }

# Приоритет разрешения значения:
#   1. USAGE_GUARD_*                  — ручной override в терминале (разово на сессию)
#   2. CLAUDE_PLUGIN_OPTION_*         — из диалога /plugin userConfig (~/.claude/settings.json)
#   3. ~/.config/usage-guard/limits.json  — персистентный пользовательский конфиг
#   4. config/limits.json плагина     — defaults из манифеста
#   5. hard-coded fallback            — на случай полного отсутствия конфига
MODE="${USAGE_GUARD_MODE:-${CLAUDE_PLUGIN_OPTION_MODE:-$(cfg '.mode')}}"
THRESHOLD="${USAGE_GUARD_BLOCK_PCT:-${CLAUDE_PLUGIN_OPTION_BLOCK_PCT:-$(cfg '.threshold_block_pct')}}"
WARN="${USAGE_GUARD_WARN_PCT:-${CLAUDE_PLUGIN_OPTION_WARN_PCT:-$(cfg '.threshold_warn_pct')}}"
THROTTLE="${USAGE_GUARD_THROTTLE:-${CLAUDE_PLUGIN_OPTION_THROTTLE_SECONDS:-$(cfg '.throttle_seconds')}}"
TOKEN_LIMIT_FIXED="${USAGE_GUARD_TOKEN_LIMIT:-${CLAUDE_PLUGIN_OPTION_TOKEN_LIMIT:-$(cfg '.token_limit_5h')}}"
RESUME_PROMPT="${USAGE_GUARD_RESUME_PROMPT:-${CLAUDE_PLUGIN_OPTION_RESUME_PROMPT:-$(cfg '.resume_prompt')}}"
BUFFER_MIN="${USAGE_GUARD_BUFFER_MIN:-$(cfg '.reset_buffer_minutes')}"
SKIP_LIST="$(jq -r '.skip_tools[]? // empty' "$CONFIG_FILE" 2>/dev/null)"

: "${MODE:=auto}"
: "${THRESHOLD:=98}"
: "${WARN:=90}"
: "${THROTTLE:=30}"
: "${BUFFER_MIN:=2}"
: "${RESUME_PROMPT:=Лимит сброшен. Продолжай работу с того места, где остановился.}"

# Skip whitelisted tools (including self-scheduling tools).
if [[ -n "$TOOL_NAME" && -n "$SKIP_LIST" ]]; then
  while IFS= read -r skip; do
    [[ "$TOOL_NAME" == "$skip" ]] && exit 0
  done <<<"$SKIP_LIST"
fi

# --- Throttle -------------------------------------------------------------

NOW="$(date +%s)"
LAST="$(cat "$LOCK" 2>/dev/null || echo 0)"
DELTA=$((NOW - LAST))
if (( DELTA < THROTTLE )); then
  exit 0
fi
printf '%s' "$NOW" >"$LOCK"

# --- ccusage query --------------------------------------------------------

CCU_OUT="$("${CCUSAGE_CMD[@]}" blocks --json --active 2>/dev/null || true)"
if [[ -z "$CCU_OUT" ]]; then
  log "ccusage returned empty output"
  exit 0
fi

BLOCK="$(printf '%s' "$CCU_OUT" | jq -c '.blocks[] | select(.isActive==true)' 2>/dev/null | head -n1)"
if [[ -z "$BLOCK" ]]; then
  log "no active block"
  exit 0
fi

TOTAL="$(printf '%s' "$BLOCK" | jq -r '.totalTokens // 0')"
END_TIME="$(printf '%s' "$BLOCK" | jq -r '.endTime // ""')"

# --- Token limit resolution ----------------------------------------------

if [[ "$MODE" == "fixed" && -n "$TOKEN_LIMIT_FIXED" ]]; then
  LIMIT="$TOKEN_LIMIT_FIXED"
else
  # auto: берём максимум totalTokens по всем историческим блокам.
  ALL_OUT="$("${CCUSAGE_CMD[@]}" blocks --json 2>/dev/null || true)"
  LIMIT="$(printf '%s' "$ALL_OUT" | jq -r '[.blocks[].totalTokens // 0] | max // 0' 2>/dev/null)"
  # Защита от нулевого лимита (нет истории) — fallback на fixed.
  if [[ -z "$LIMIT" || "$LIMIT" == "0" || "$LIMIT" == "null" ]]; then
    LIMIT="${TOKEN_LIMIT_FIXED:-220000000}"
  fi
fi

# --- Compute percentage --------------------------------------------------

if (( LIMIT <= 0 )); then
  log "bad limit: $LIMIT"
  exit 0
fi

# Percentage с одним знаком после запятой — через awk, без bc.
# LC_NUMERIC=C — чтобы разделитель всегда был точка, не запятая (локаль-independent).
PCT="$(LC_NUMERIC=C awk -v t="$TOTAL" -v l="$LIMIT" 'BEGIN{printf "%.1f", (t/l)*100}')"
PCT_INT="$(LC_NUMERIC=C awk -v t="$TOTAL" -v l="$LIMIT" 'BEGIN{printf "%d", (t/l)*100}')"

log "used=$TOTAL limit=$LIMIT pct=$PCT end=$END_TIME tool=$TOOL_NAME"

# --- Decision ------------------------------------------------------------

if (( PCT_INT >= THRESHOLD )); then
  # Reset time + buffer, в локальной таймзоне в ISO для CronCreate.
  RESUME_AT=""
  if [[ -n "$END_TIME" && "$END_TIME" != "null" ]]; then
    # BSD date (macOS) требует отдельного формата ввода.
    if date -j >/dev/null 2>&1; then
      EPOCH="$(date -j -u -f "%Y-%m-%dT%H:%M:%S" "${END_TIME%.*}" +%s 2>/dev/null || echo 0)"
    else
      EPOCH="$(date -u -d "$END_TIME" +%s 2>/dev/null || echo 0)"
    fi
    if (( EPOCH > 0 )); then
      RESUME_EPOCH=$((EPOCH + BUFFER_MIN * 60))
      if date -j >/dev/null 2>&1; then
        RESUME_AT="$(date -j -r "$RESUME_EPOCH" +"%Y-%m-%dT%H:%M:%S%z")"
      else
        RESUME_AT="$(date -d "@$RESUME_EPOCH" +"%Y-%m-%dT%H:%M:%S%z")"
      fi
    fi
  fi

  {
    echo "[usage-guard] BLOCK: потребление 5-часового лимита достигло ${PCT}% (${TOTAL}/${LIMIT} токенов)."
    echo ""
    echo "Действия (строго в этом порядке):"
    echo "  1. Вызови инструмент CronCreate с параметрами:"
    echo "       schedule: '${RESUME_AT:-после сброса лимита (~$END_TIME + ${BUFFER_MIN} мин)}'"
    echo "       prompt: '${RESUME_PROMPT}'"
    echo "     (CronCreate session-scoped — когда триггер сработает,"
    echo "      prompt придёт как новый turn в эту же сессию с полным контекстом.)"
    echo "  2. После успешного создания триггера — ответь пользователю одной строкой:"
    echo "     'Лимит 98% — поставил возобновление на ${RESUME_AT:-$END_TIME}. Жду.'"
    echo "  3. Не делай никаких других tool calls до срабатывания триггера."
    echo ""
    echo "Не пытайся повторить заблокированный вызов — он съест остаток лимита."
  } >&2
  exit 2
fi

if (( PCT_INT >= WARN )); then
  echo "[usage-guard] WARN: 5h usage at ${PCT}% (threshold ${THRESHOLD}%). Reset at $END_TIME." >&2
fi

exit 0
