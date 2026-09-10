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
  [ -n "${slow_pid:-}" ] && kill "$slow_pid" 2>/dev/null
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

# Вторая шина — медленная: держит запрос, пока мы смотрим в список процессов.
slow_port=$((port + 1))
sed 's/def do_POST(self):/def do_POST(self):\n        import time; time.sleep(6)/' "$work/bus.py" > "$work/slow.py"
python3 "$work/slow.py" "$slow_port" &
slow_pid=$!

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
# Живой замок ТОЙ ЖЕ сессии: второй хук не нужен.
#
# `run` запускает хук прямо отсюда, значит его сессия — этот тест ($$).
# Кладём в замок ровно её: хук обязан увидеть своё же дежурство и тихо
# уйти. Без этого правила каждый ход в чате рвал бы ожидание.
mkdir -p "$work/home/.relay/locks/-дом-проект-а"
echo $$ > "$work/home/.relay/locks/-дом-проект-а/pid"
echo $$ > "$work/home/.relay/locks/-дом-проект-а/session"
run /дом/проект-а
check "своё дежурство уже идёт — уходим тихо" "$?" "0"
# А соседний проект — это другой агент, и его дежурство останавливать нельзя.
run /дом/проект-б
check "соседний проект дежурит как ни в чём не бывало" "$?" "2"
rm -rf "$work/home/.relay/locks/-дом-проект-а"

echo
echo "токен не виден в списке процессов"
# Пока хук ждёт, ищем токен в аргументах всех процессов машины.
#
# `ps` показывает аргументы ВСЕХ процессов, и заголовок, переданный через
# `-H "Bearer …"`, клал трёхмесячный ключ на всеобщее обозрение: на сервере с
# постоянным агентом его прочитал бы любой процесс. Найдено на живой
# установке 2026-09-10.
(
  HOME="$work/home" \
  RELAY_URL="http://127.0.0.1:$slow_port" \
  CLAUDE_PROJECT_DIR=/дом/проект-а \
    sh "$hook" >/dev/null 2>&1 &
  echo $! > "$work/hook.pid"
)
sleep 1

# Скобки в образце — чтобы сам `grep` не попал в собственный вывод: его
# аргументы тоже видны в `ps`, и без этого проверка всегда «находит» утечку.
token_visible() { ps -Ao args 2>/dev/null | grep -q "TOKEN[-]A"; }

# Сначала — сам хук: пока он ждёт, токена в аргументах быть не должно.
if token_visible; then
  echo "  ПРОВАЛ токен виден в аргументах процессов"
  ps -Ao pid,args 2>/dev/null | grep "TOKEN[-]A" | head -3 | sed 's/^/       /'
  failed=$((failed + 1))
else
  echo "  ok   токен в аргументах не светится"
fi

# А теперь убеждаемся, что проверка вообще умеет видеть утечку: запускаем
# заведомо дырявый процесс с токеном в аргументах. Без этого зелёный
# результат выше ничего не значил бы.
#
# Две команды, а не одна: с одной оболочка подменяет себя ею же (`exec`), и
# подставной аргумент исчезает вместе с ней.
sh -c 'sleep 3; :' TOKEN-A &
control_pid=$!
sleep 0.5

if token_visible; then
  echo "  ok   проверка умеет видеть утечку"
else
  echo "  ПРОВАЛ проверка слепа — зелёный результат выше ничего не доказал"
  failed=$((failed + 1))
fi

kill "$control_pid" 2>/dev/null

kill "$(cat "$work/hook.pid")" 2>/dev/null
pkill -f "$slow_port/v1/duty/wait" 2>/dev/null
rm -rf "$work/home/.relay/locks"

echo
echo "дежурство уходит за человеком в другой чат"
# Замок держит СЕССИЮ, а не процесс. Своя же сессия второй раз ничего не
# трогает — иначе каждый ход рвал бы ожидание. А чужая забирает: человек ушёл
# в другой чат, и дежурство идёт за ним.
#
# Живой случай 2026-09-10: хук пережил закрытый чат, держал замок и забирал
# письма в сессию, которой уже нет. Письмо при этом помечалось показанным —
# то есть пропадало.
#
# Две команды в обёртке, а не одна: с одной оболочка подменяет себя хуком
# (`exec`), и у обоих хуков оказался бы один и тот же родитель — то есть одна
# и та же «сессия», и перехват было бы не проверить.
lock="$work/home/.relay/locks/-дом-проект-а"

run_hook_in_own_session() {
  HOME="$work/home" RELAY_URL="http://127.0.0.1:$slow_port" \
  CLAUDE_PROJECT_DIR=/дом/проект-а \
    sh -c 'sh "$0"; :' "$hook" >/dev/null 2>&1 &
}

run_hook_in_own_session
sleep 1
first_pid=$(cat "$lock/pid" 2>/dev/null || echo '')
first_session=$(cat "$lock/session" 2>/dev/null || echo '')

if [ -n "$first_pid" ] && [ -n "$first_session" ]; then
  echo "  ok   первый хук занял замок и записал свою сессию"
else
  echo "  ПРОВАЛ замок не занят"
  failed=$((failed + 1))
fi

# Второй хук ТОЙ ЖЕ сессии: запускаем прямо из-под первой обёртки нельзя,
# поэтому проверяем то же правило иначе — подсовываем замку сессию, равную
# родителю нового хука. Родителем будет обёртка, её номер и запишем.
run_hook_in_own_session
sleep 1
second_pid=$(cat "$lock/pid" 2>/dev/null || echo '')

if [ "$second_pid" != "$first_pid" ] && [ -n "$second_pid" ]; then
  echo "  ok   хук чужой сессии забрал дежурство себе"
else
  echo "  ПРОВАЛ дежурство осталось у прежней сессии"
  failed=$((failed + 1))
fi

# А прежний обязан заметить это и уйти сам.
waited=0
while kill -0 "$first_pid" 2>/dev/null && [ "$waited" -lt 12 ]; do
  sleep 1
  waited=$((waited + 1))
done

if kill -0 "$first_pid" 2>/dev/null; then
  echo "  ПРОВАЛ прежний хук не ушёл — два ожидания на один инстанс"
  failed=$((failed + 1))
else
  echo "  ok   прежний хук заметил и ушёл"
fi

pkill -f "$slow_port/v1/duty/wait" 2>/dev/null
pkill -f "sh $hook" 2>/dev/null
rm -rf "$work/home/.relay/locks"

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
