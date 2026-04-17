#!/usr/bin/env bash
# Включить/выключить usage-guard через флаг-файл.
# Usage: toggle.sh on|off|status
set -u

STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/usage-guard"
KILL_SWITCH="$STATE_DIR/disabled"
mkdir -p "$STATE_DIR"

case "${1:-status}" in
  off|disable)
    touch "$KILL_SWITCH"
    echo "✗ usage-guard DISABLED (флаг: $KILL_SWITCH)"
    echo "  Разовый override без флага: USAGE_GUARD_DISABLE=1 claude"
    ;;
  on|enable)
    rm -f "$KILL_SWITCH"
    echo "✓ usage-guard ENABLED"
    ;;
  status|*)
    if [[ -f "$KILL_SWITCH" ]]; then
      echo "usage-guard: DISABLED (флаг $KILL_SWITCH существует)"
    else
      echo "usage-guard: ENABLED"
    fi
    ;;
esac
