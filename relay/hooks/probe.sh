#!/bin/sh
# Проба: записывает, что хук вообще сработал и что он видит.
# Ничего не делает с Relay — задача узнать факты, а не подключиться.
log="${CLAUDE_PLUGIN_DATA:-/tmp}/probe.log"
mkdir -p "$(dirname "$log")" 2>/dev/null
{
  echo "--- $(date -u +%FT%TZ) событие=$1"
  echo "PLUGIN_ROOT=${CLAUDE_PLUGIN_ROOT:-НЕТ}"
  echo "PLUGIN_DATA=${CLAUDE_PLUGIN_DATA:-НЕТ}"
  echo "PROJECT_DIR=${CLAUDE_PROJECT_DIR:-НЕТ}"
  echo "OPTION_URL=${CLAUDE_PLUGIN_OPTION_URL:-НЕТ}"
  echo "OPTION_INSTANCE=${CLAUDE_PLUGIN_OPTION_INSTANCE:-НЕТ}"
} >> "$log" 2>/dev/null
exit 0
