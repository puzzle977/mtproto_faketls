# mtproto_faketls вайбкод

Для установки арендуем vps сервер с минимальным конфигом, ставил на timeweb cloud. (реф ссылка https://timeweb.cloud/?i=126855)

Логинимся по ssh на арендованный сервер.

Перед запуском устанавливаем выполняя команду apt install docker.io

sudo bash <(curl -Ls https://raw.githubusercontent.com/puzzle977/mtproto_faketls/refs/heads/main/start-mtproxy.sh)

chmod +x start-mtproxy.sh

Далее скрипт можно запускать командой:
sudo ./start-mtproxy.sh


Инструкция по пунктам меню:
1) Создать новый прокси
   - создаёт новый Docker-контейнер MTProto Proxy
   - можно указать своё название
   - можно указать свой порт
   - если нажать Enter, имя и порт будут выбраны автоматически

2) Показать список
   - показывает все сохранённые прокси
   - отображает их статус: active / stopped / missing

3) Статус + ссылка
   - сначала показывает список активных прокси
   - после выбора выводит статус, IP, порт, secret и tg:// ссылку

4) Удалить прокси
   - сначала показывает список активных прокси
   - удаляет контейнер и все сохранённые данные прокси

5) Просмотр логов
   - сначала показывает список активных прокси
   - показывает последние 100 строк логов контейнера

6) Справка
   - выводит эту подсказку




Протестировано на ubuntu 22

```bash
#!/bin/bash

set -u

BASE_DIR="/opt/mtproto-manager"
PROXY_IMAGE="telegrammessenger/proxy"
CONTAINER_PREFIX="mtproto-proxy"
DEFAULT_PORT_START=443

mkdir -p "$BASE_DIR"

require_root() {
  if [[ "$EUID" -ne 0 ]]; then
    echo "Запусти скрипт от root: sudo bash $0"
    exit 1
  fi
}

check_dependencies() {
  local missing=()

  command -v docker >/dev/null 2>&1 || missing+=("docker")
  command -v openssl >/dev/null 2>&1 || missing+=("openssl")
  command -v curl >/dev/null 2>&1 || missing+=("curl")

  if [[ ${#missing[@]} -gt 0 ]]; then
    echo "Не хватает зависимостей: ${missing[*]}"
    exit 1
  fi
}

get_public_ip() {
  local ip=""
  ip=$(curl -4 -s ifconfig.me 2>/dev/null || true)

  if [[ -z "$ip" ]]; then
    ip=$(curl -4 -s api.ipify.org 2>/dev/null || true)
  fi

  echo "$ip"
}

generate_proxy_id() {
  date +%s%N | cut -b1-13
}

find_free_port() {
  local port=${1:-$DEFAULT_PORT_START}

  while true; do
    if ! docker ps -a --format '{{.Ports}}' | grep -qE "(0\.0\.0\.0|:::)$port->"; then
      echo "$port"
      return
    fi
    ((port++))
  done
}

proxy_dir_by_id() {
  echo "$BASE_DIR/$1"
}

meta_file_by_id() {
  echo "$(proxy_dir_by_id "$1")/meta.conf"
}

load_proxy_meta() {
  local id="$1"
  local file
  file=$(meta_file_by_id "$id")

  if [[ -f "$file" ]]; then
    # shellcheck disable=SC1090
    source "$file"
    return 0
  fi

  return 1
}

save_proxy_meta() {
  local id="$1"
  local name="$2"
  local port="$3"
  local secret="$4"
  local ip="$5"
  local container="$6"

  local dir
  dir=$(proxy_dir_by_id "$id")
  mkdir -p "$dir"

  cat > "$(meta_file_by_id "$id")" <<EOF
ID="$id"
NAME="$name"
PORT="$port"
SECRET="$secret"
IP="$ip"
CONTAINER_NAME="$container"
EOF
}

cleanup_missing_meta() {
  local dir id container

  for dir in "$BASE_DIR"/*; do
    [[ -d "$dir" ]] || continue
    id=$(basename "$dir")

    if load_proxy_meta "$id"; then
      container="$CONTAINER_NAME"
      if ! docker inspect "$container" >/dev/null 2>&1; then
        rm -rf "$dir"
      fi
    else
      rm -rf "$dir"
    fi
  done
}

get_all_proxy_ids() {
  local dir
  for dir in "$BASE_DIR"/*; do
    [[ -d "$dir" ]] || continue
    basename "$dir"
  done | sort
}

get_active_proxy_ids() {
  local id
  for id in $(get_all_proxy_ids); do
    if load_proxy_meta "$id"; then
      if docker ps --format '{{.Names}}' | grep -Fxq "$CONTAINER_NAME"; then
        echo "$id"
      fi
    fi
  done
}

print_header() {
  clear
  echo "🚀 Менеджер MTProto Proxy"
  echo "=============================="
}

print_main_menu() {
  echo "   1) ➕ Создать новый прокси"
  echo "   2) 📋 Показать список"
  echo "   3) 📊 Статус + ссылка"
  echo "   4) 🗑️  Удалить прокси"
  echo "   5) 📋 Просмотр логов"
  echo "   6) ℹ️  Справка"
  echo "   0) 🚪 Выход"
  echo
}

pause() {
  echo
  read -rp "Нажми Enter для продолжения..."
}

show_proxy_list() {
  local ids id status
  ids=$(get_all_proxy_ids)

  if [[ -z "$ids" ]]; then
    echo "Прокси пока нет."
    return 1
  fi

  echo "Список прокси:"
  echo "=============================="

  local i=1
  while read -r id; do
    [[ -n "$id" ]] || continue

    if load_proxy_meta "$id"; then
      if docker ps --format '{{.Names}}' | grep -Fxq "$CONTAINER_NAME"; then
        status="🟢 active"
      elif docker inspect "$CONTAINER_NAME" >/dev/null 2>&1; then
        status="🟡 stopped"
      else
        status="🔴 missing"
      fi

      echo "[$i] $NAME | ID: $ID | PORT: $PORT | CONTAINER: $CONTAINER_NAME | $status"
      ((i++))
    fi
  done <<< "$ids"

  return 0
}

select_active_proxy() {
  local selected index=1 id
  local ids=()

  while read -r id; do
    [[ -n "$id" ]] || continue
    ids+=("$id")
  done < <(get_active_proxy_ids)

  if [[ ${#ids[@]} -eq 0 ]]; then
    echo
    echo "Активных прокси нет."
    return 1
  fi

  echo "Активные прокси:"
  echo "=============================="
  for id in "${ids[@]}"; do
    if load_proxy_meta "$id"; then
      echo "[$index] $NAME | ID: $ID | PORT: $PORT | CONTAINER: $CONTAINER_NAME"
      ((index++))
    fi
  done

  echo
  read -rp "Выбери номер: " selected

  if ! [[ "$selected" =~ ^[0-9]+$ ]]; then
    echo "Некорректный ввод."
    return 1
  fi

  if (( selected < 1 || selected > ${#ids[@]} )); then
    echo "Нет такого пункта."
    return 1
  fi

  SELECTED_PROXY_ID="${ids[$((selected - 1))]}"
  return 0
}

create_proxy() {
  print_header
  echo "➕ Создание нового прокси"
  echo "=============================="

  local id name port secret ip container
  local custom_name custom_port

  id=$(generate_proxy_id)

  read -rp "Введите название прокси (Enter = auto): " custom_name
  if [[ -z "$custom_name" ]]; then
    name="proxy-$id"
  else
    name="$custom_name"
  fi

  read -rp "Введите порт (Enter = авто): " custom_port
  if [[ -z "$custom_port" ]]; then
    port=$(find_free_port "$DEFAULT_PORT_START")
  else
    if ! [[ "$custom_port" =~ ^[0-9]+$ ]]; then
      echo "❌ Порт должен быть числом."
      pause
      return
    fi

    if (( custom_port < 1 || custom_port > 65535 )); then
      echo "❌ Порт должен быть в диапазоне 1-65535."
      pause
      return
    fi

    if docker ps -a --format '{{.Ports}}' | grep -qE "(0\.0\.0\.0|:::)$custom_port->"; then
      echo "❌ Порт уже занят."
      pause
      return
    fi

    port="$custom_port"
  fi

  secret=$(openssl rand -hex 16)
  ip=$(get_public_ip)
  container="${CONTAINER_PREFIX}-${id}"

  echo
  echo "Имя: $name"
  echo "Порт: $port"
  echo "Secret: $secret"
  echo "IP: ${ip:-не удалось определить}"
  echo

  echo "📦 Запускаем контейнер..."
  if docker run -d \
    --name "$container" \
    --restart unless-stopped \
    -p "$port:443" \
    -e SECRET="$secret" \
    "$PROXY_IMAGE" >/dev/null 2>&1; then

    save_proxy_meta "$id" "$name" "$port" "$secret" "$ip" "$container"

    echo
    echo "✅ Прокси успешно создан"
    echo "=============================="
    echo "ID: $id"
    echo "NAME: $name"
    echo "CONTAINER: $container"
    echo "IP: ${ip:-не удалось определить}"
    echo "PORT: $port"
    echo "SECRET: $secret"
    echo
    if [[ -n "$ip" ]]; then
      echo "🔗 ССЫЛКА:"
      echo "tg://proxy?server=$ip&port=$port&secret=$secret"
    else
      echo "⚠️ Не удалось определить внешний IP."
    fi
    echo "=============================="
  else
    echo "❌ Ошибка запуска контейнера"
    docker logs "$container" 2>/dev/null || true
  fi

  pause
}

list_proxies() {
  print_header
  echo "📋 Список прокси"
  echo "=============================="
  cleanup_missing_meta
  show_proxy_list || true
  pause
}

proxy_status_and_link() {
  print_header
  echo "📊 Статус + ссылка"
  echo "=============================="

  if ! select_active_proxy; then
    pause
    return
  fi

  if ! load_proxy_meta "$SELECTED_PROXY_ID"; then
    echo "Не удалось загрузить данные прокси."
    pause
    return
  fi

  local running="нет"
  if docker ps --format '{{.Names}}' | grep -Fxq "$CONTAINER_NAME"; then
    running="да"
  fi

  local current_ip="${IP}"
  if [[ -z "$current_ip" ]]; then
    current_ip=$(get_public_ip)
  fi

  echo
  echo "Информация о прокси:"
  echo "=============================="
  echo "ID: $ID"
  echo "NAME: $NAME"
  echo "CONTAINER: $CONTAINER_NAME"
  echo "STATUS: $running"
  echo "IP: ${current_ip:-не удалось определить}"
  echo "PORT: $PORT"
  echo "SECRET: $SECRET"
  echo

  if [[ -n "$current_ip" ]]; then
    echo "🔗 ССЫЛКА:"
    echo "tg://proxy?server=$current_ip&port=$PORT&secret=$SECRET"
  else
    echo "⚠️ Не удалось определить IP."
  fi

  echo "=============================="
  pause
}

delete_proxy() {
  print_header
  echo "🗑️ Удаление прокси"
  echo "=============================="

  if ! select_active_proxy; then
    pause
    return
  fi

  if ! load_proxy_meta "$SELECTED_PROXY_ID"; then
    echo "Не удалось загрузить данные прокси."
    pause
    return
  fi

  echo
  echo "Будет удалено:"
  echo "NAME: $NAME"
  echo "ID: $ID"
  echo "CONTAINER: $CONTAINER_NAME"
  echo "PORT: $PORT"
  echo

  read -rp "Подтвердить удаление? [y/N]: " confirm
  if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
    echo "Удаление отменено."
    pause
    return
  fi

  echo
  echo "Удаляем контейнер..."
  docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true

  echo "Удаляем данные..."
  rm -rf "$(proxy_dir_by_id "$SELECTED_PROXY_ID")"

  echo "✅ Прокси удалён полностью."
  pause
}

show_proxy_logs() {
  print_header
  echo "📋 Просмотр логов"
  echo "=============================="

  if ! select_active_proxy; then
    pause
    return
  fi

  if ! load_proxy_meta "$SELECTED_PROXY_ID"; then
    echo "Не удалось загрузить данные прокси."
    pause
    return
  fi

  echo
  echo "Логи контейнера: $CONTAINER_NAME"
  echo "=============================="
  docker logs --tail 100 "$CONTAINER_NAME" 2>&1
  echo "=============================="

  pause
}

show_help() {
  print_header
  cat <<'EOF'
ℹ️ Справка
==============================
1) Создать новый прокси
   - создаёт новый Docker-контейнер MTProto Proxy
   - можно указать своё название
   - можно указать свой порт
   - если нажать Enter, имя и порт будут выбраны автоматически

2) Показать список
   - показывает все сохранённые прокси
   - отображает их статус: active / stopped / missing

3) Статус + ссылка
   - сначала показывает список активных прокси
   - после выбора выводит статус, IP, порт, secret и tg:// ссылку

4) Удалить прокси
   - сначала показывает список активных прокси
   - удаляет контейнер и все сохранённые данные прокси

5) Просмотр логов
   - сначала показывает список активных прокси
   - показывает последние 100 строк логов контейнера

6) Справка
   - выводит эту подсказку
==============================
EOF
  pause
}

main_loop() {
  while true; do
    cleanup_missing_meta
    print_header
    print_main_menu

    read -rp "Выбери пункт: " choice
    echo

    case "$choice" in
      1) create_proxy ;;
      2) list_proxies ;;
      3) proxy_status_and_link ;;
      4) delete_proxy ;;
      5) show_proxy_logs ;;
      6) show_help ;;
      0)
        echo "Выход."
        exit 0
        ;;
      *)
        echo "Некорректный пункт меню."
        pause
        ;;
    esac
  done
}

require_root
check_dependencies
main_loop
```
