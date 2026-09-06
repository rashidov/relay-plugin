#!/bin/sh
# Проверка хука дежурства — настоящим запуском, против подставной шины.
#
# Шелл дважды ломался молча: один раз кавычка-ёлочка ушла в имя переменной,
# другой раз ожидание делало один заход и умирало. Оба раза выглядело как
# рабочее. Поэтому здесь не чтение кода, а запуск: поднимаем шину на порту,
# запускаем хук и смотрим, с чем он вышел.
#
# Запуск: sh test/duty.test.sh
set -u

root=$(cd "$(dirname "$0")/.." && pwd)
hook="$root/relay/hooks/duty.sh"
work=$(mktemp -d)
port=$((8000 + $$ % 1000))
failed=0

cleanup() {
  [ -n "${bus_pid:-}" ] && kill "$bus_pid" 2>/dev/null
  rm -rf "$work"
}
trap cleanup EXIT INT TERM

# Подставная шина. Отвечает текстом и говорит, каким токеном к ней пришли, —
# так проверяется, что хук взял файл своего проекта, а не соседнего.
cat > "$work/bus.py" <<'PY'
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer


class Bus(BaseHTTPRequestHandler):
    def do_POST(self):
        self.rfile.read(int(self.headers.get('content-length', 0)))
        token = self.headers.get('authorization', '').replace('Bearer ', '')
        body = f'Relay: пришло входящее. токен={token}'.encode()
        self.send_response(200)
        self.send_header('content-type', 'text/plain; charset=utf-8')
        self.send_header('content-length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass


HTTPServer(('127.0.0.1', int(sys.argv[1])), Bus).serve_forever()
PY

python3 "$work/bus.py" "$port" &
bus_pid=$!

# Ждём, пока шина поднимется: без этого первый же прогон ловит отказ связи и
# уходит в паузу, а тест выглядит зависшим.
i=0
while [ "$i" -lt 50 ]; do
  curl -sS -m 1 -X POST "http://127.0.0.1:$port/" >/dev/null 2>&1 && break
  i=$((i + 1))
  sleep 0.1
done

# Один запуск хука за проект. Возвращает код выхода, stderr — в файле.
run() {
  HOME="$work/home" \
  RELAY_URL="http://127.0.0.1:$port" \
  CLAUDE_PROJECT_DIR="$1" \
    sh "$hook" 2>"$work/err" >"$work/out"
}

check() {
  if [ "$2" = "$3" ]; then
    echo "  ok   $1"
  else
    echo "  ПРОВАЛ $1"
    echo "       ждали: $3"
    echo "       вышло: $2"
    failed=$((failed + 1))
  fi
}

contains() {
  if grep -qF "$3" "$work/err"; then
    echo "  ok   $1"
  else
    echo "  ПРОВАЛ $1"
    echo "       нет строки: $3"
    echo "       stderr: $(cat "$work/err")"
    failed=$((failed + 1))
  fi
}

echo "молчит, когда дежурить нечем"
run /дом/проект-а
check "выход нулём" "$?" "0"
check "ни слова в stderr" "$(cat "$work/err")" ""

echo
echo "будит, когда работа пришла"
mkdir -p "$work/home/.relay/tokens"
printf 'TOKEN-A' > "$work/home/.relay/tokens/-дом-проект-а"
run /дом/проект-а
check "выход двойкой" "$?" "2"
contains "текст письма ушёл в stderr" _ "пришло входящее"

echo
echo "каждый проект берёт СВОЙ токен — ради этого всё и делалось"
printf 'TOKEN-B' > "$work/home/.relay/tokens/-дом-проект-б"
run /дом/проект-б
contains "проект Б пришёл своим токеном" _ "токен=TOKEN-B"
run /дом/проект-а
contains "проект А пришёл своим токеном" _ "токен=TOKEN-A"

echo
echo "замок держится на проект, а не на машину"
# Живой замок проекта А: второе дежурство того же проекта не нужно.
mkdir -p "$work/home/.relay/locks/-дом-проект-а"
echo $$ > "$work/home/.relay/locks/-дом-проект-а/pid"
run /дом/проект-а
check "своё дежурство уже идёт — уходим тихо" "$?" "0"
# А соседний проект — это другой агент, и его дежурство останавливать нельзя.
run /дом/проект-б
check "соседний проект дежурит как ни в чём не бывало" "$?" "2"
rm -rf "$work/home/.relay/locks/-дом-проект-а"

echo
echo "мёртвый замок снимается сам"
mkdir -p "$work/home/.relay/locks/-дом-проект-а"
echo 999999 > "$work/home/.relay/locks/-дом-проект-а/pid"
run /дом/проект-а
check "дежурство поднялось поверх мёртвого замка" "$?" "2"

echo
if [ "$failed" -eq 0 ]; then
  echo "всё сошлось"
  exit 0
fi

echo "провалов: $failed"
exit 1
