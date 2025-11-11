#!/bin/sh
#
# Shpun Router — генератор кода роутера
# Формат: XXXX-XXXX (буквы A–F и цифры)
# Используется для первичной привязки роутера к VPN через Telegram-бота.

STATE_DIR="/etc/shpun"
CODE_FILE="$STATE_DIR/router_code"

set -eu

# Создаём каталог состояния, если его нет
mkdir -p "$STATE_DIR" || {
	echo "Failed to create $STATE_DIR" >&2
	exit 1
}

# Если код уже существует — просто вывести и выйти
if [ -s "$CODE_FILE" ]; then
	CODE="$(cat "$CODE_FILE")"
	printf 'Router code: %s\n' "$CODE"
	exit 0
fi

# Генерация случайного блока (через openssl, если есть)
if command -v openssl >/dev/null 2>&1; then
	RAW="$(openssl rand -hex 4 | tr 'a-f' 'A-F')"
else
	# fallback: берём хэш от текущего времени, оставляем 8 символов (A-F0-9)
	RAW="$(date +%s%N | md5sum | awk '{print toupper($1)}' | cut -c1-8)"
fi

# Формируем код XXXX-XXXX
CODE="$(echo "$RAW" | cut -c1-4)-$(echo "$RAW" | cut -c5-8)"

# Сохраняем и показываем результат
echo "$CODE" > "$CODE_FILE"
echo "Generated router code: $CODE"
