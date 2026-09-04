#!/bin/sh
# Дежурство Relay: ждём работу и будим агента, когда она пришла.
#
# Программы для этого не нужно. Ожидание — висящий запрос к шине, а текст
# письма собирает она же: нам остаётся отдать его как есть и выйти двойкой.
# Claude Code на двойке будит агента и показывает написанное в stderr.
set -u

url="${CLAUDE_PLUGIN_OPTION_URL:-}"
token_file="$HOME/.relay/token"

# Не настроено — молчим. Кричать там, где ничего не обещано, так же неверно,
# как молчать там, где обещано.
[ -n "$url" ] || exit 0
[ -r "$token_file" ] || exit 0

# Кто дежурит: рабочее место, а не процесс. Хук перезапускается на каждом
# ходе, и отпечаток процесса менялся бы каждый раз — дежурство отказывало бы
# самому себе. Наружу уходит хэш: имя каталога это часто имя проекта и имя
# человека.
holder=$(printf '%s' "$(hostname)|${CLAUDE_PROJECT_DIR:-}" \
  | { shasum -a 256 2>/dev/null || sha256sum 2>/dev/null; } \
  | cut -c1-32)

out=$(curl -sS -m 100 -X POST "$url/v1/duty/wait" \
  -H "authorization: Bearer $(cat "$token_file")" \
  -H 'accept: text/plain' \
  -H 'content-type: application/json' \
  -d "{\"timeout\":90,\"holder\":\"$holder\"}" 2>/dev/null) || exit 0

# Пусто — значит за окно ожидания ничего не пришло. Это не повод будить.
[ -n "$out" ] || exit 0

printf '%s\n' "$out" >&2
exit 2
