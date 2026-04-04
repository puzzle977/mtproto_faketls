#!/bin/bash
set -u

# ==================== КОНФИГУРАЦИЯ ====================
BASE_DIR="/opt/mtproto-manager"
PROXY_REPO="https://github.com/alexbers/mtprotoproxy.git"
PROXY_DIR="$BASE_DIR/mtprotoproxy-src"
CONTAINER_PREFIX="mtproto-proxy"
DEFAULT_PORT=443
DEFAULT_TLS_DOMAIN="cloudflare.com"

mkdir -p "$BASE_DIR"

# ==================== УТИЛИТЫ ====================

require_root() {
  if [[ "$EUID" -ne 0 ]]; then
    echo "❌ Запусти скрипт от root: sudo bash $0" >&2
    exit 1
  fi
}

check_dependencies() {
  local missing=()
  command -v docker >/dev/null 2>&1 || missing+=("docker")
  command -v git >/dev/null 2>&1 || missing+=("git")
  command -v openssl >/dev/null 2>&1 || missing+=("openssl")
  command -v curl >/dev/null 2>&1 || missing+=("curl")
  command -v xxd >/dev/null 2>&1 || missing+=("xxd")
  command -v ss >/dev/null 2>&1 || missing+=("iproute2")

  if [[ ${#missing[@]} -gt 0 ]]; then
    echo "❌ Не хватает: ${missing[*]}" >&2
    echo "💡 Установите: apt install docker.io git openssl curl xxd iproute2 -y" >&2
    exit 1
  fi
}

get_public_ip() {
  local ip=""
  ip=$(curl -4 -s --connect-timeout 5 ifconfig.me 2>/dev/null || true)
  [[ -z "$ip" ]] && ip=$(curl -4 -s --connect-timeout 5 api.ipify.org 2>/dev/null || true)
  [[ -z "$ip" ]] && ip=$(curl -4 -s --connect-timeout 5 icanhazip.com 2>/dev/null || true)
  echo "$ip"
}

generate_proxy_id() {
  date +%s%N | cut -b1-13
}

generate_secret_hex() {
  openssl rand -hex 16
}

# Генерация secret ТОЛЬКО для Fake TLS (ee-префикс)
generate_ee_secret() {
  local domain="${1:-$DEFAULT_TLS_DOMAIN}"
  local base_secret; base_secret=$(generate_secret_hex)
  local domain_hex; domain_hex=$(echo -n "$domain" | xxd -ps | tr -d '\n')
  echo "ee${base_secret}${domain_hex}"
}

# Извлечение 32-символьного base secret из ee-строки
extract_base_from_ee() {
  local full="$1"
  # Убираем "ee" и домен в конце, оставляем 32 hex символа ключа
  echo "$full" | sed 's/^ee//' | grep -oE '^[0-9a-fA-F]{32}'
}

proxy_dir_by_id() { echo "$BASE_DIR/$1"; }
meta_file_by_id() { echo "$(proxy_dir_by_id "$1")/meta.conf"; }
config_file_by_id() { echo "$(proxy_dir_by_id "$1")/config.py"; }

# ==================== МЕТА-ДАННЫЕ ====================

load_proxy_meta() {
  local id="$1"
  local file; file=$(meta_file_by_id "$id")
  [[ -f "$file" ]] && source "$file" && return 0
  return 1
}

save_proxy_meta() {
  local id="$1" name="$2" port="$3" secret="$4" ip="$5" container="$6"
  local tls_domain="${7:-$DEFAULT_TLS_DOMAIN}"
  local dir; dir=$(proxy_dir_by_id "$id")
  mkdir -p "$dir"

  cat > "$(meta_file_by_id "$id")" <<EOF
ID="$id"
NAME="$name"
PORT="$port"
SECRET="$secret"
IP="$ip"
CONTAINER_NAME="$container"
MODE="fake"
TLS_DOMAIN="$tls_domain"
EOF
}

# ==================== CONFIG.PY (только TLS-режим) ====================

generate_config_py() {
  local id="$1" port="$2" secret="$3" tls_domain="${4:-$DEFAULT_TLS_DOMAIN}"

  local config_path; config_path=$(config_file_by_id "$id")
  mkdir -p "$(dirname "$config_path")"

  cat > "$config_path" <<EOF
# Auto-generated config for proxy $id (Fake TLS only)
PORT = $port
USERS = { "tg": "$secret" }

# 🔒 ТОЛЬКО Fake TLS режим — максимальная защита от DPI
MODES = {
    "classic": False,
    "secure": False,
    "tls": True
}

TLS_DOMAIN = "$tls_domain"

# Anti-DPI настройки
FAST_MODE = True
MASK = True
MASK_HOST = "$tls_domain"
MASK_PORT = 443
REPLAY_CHECK_LEN = 65536
IGNORE_TIME_SKEW = False
STATS_PRINT_PERIOD = 600

# Производительность
TO_CLT_BUFSIZE = [16384, 100, 131072]
TO_TG_BUFSIZE = 65536
CLIENT_KEEPALIVE = 600
CLIENT_HANDSHAKE_TIMEOUT = 10
CLIENT_ACK_TIMEOUT = 300
TG_CONNECT_TIMEOUT = 10
TG_READ_TIMEOUT = 60

# Сеть
LISTEN_ADDR_IPV4 = "0.0.0.0"
LISTEN_ADDR_IPV6 = "::"
METRICS_PREFIX = "mtprotoproxy_"
EOF
  return 0
}

# ==================== DOCKER ====================

clone_proxy_source() {
  if [[ ! -d "$PROXY_DIR" ]]; then
    echo "📥 Клонируем mtprotoproxy..." >&2
    git clone --depth 1 "$PROXY_REPO" "$PROXY_DIR" 2>/dev/null || return 1
  else
    echo "🔄 Обновляем исходники..." >&2
    (cd "$PROXY_DIR" && git pull --quiet 2>/dev/null || true)
  fi
  return 0
}

build_proxy_image() {
  local image_name="mtprotoproxy-local:latest"
  echo "🔨 Собираем образ $image_name..." >&2
  
  if ! docker build -t "$image_name" "$PROXY_DIR" >/dev/null 2>&1; then
    echo "❌ Ошибка сборки" >&2
    docker build -t "$image_name" "$PROXY_DIR" 2>&1 | tail -20 >&2
    return 1
  fi
  echo "$image_name"
  return 0
}

run_proxy_container() {
  local id="$1" name="$2" port="$3" secret="$4" tls_domain="${5:-$DEFAULT_TLS_DOMAIN}"

  local config_file; config_file=$(config_file_by_id "$id")
  local proxy_script="$PROXY_DIR/mtprotoproxy.py"
  local container_name="${CONTAINER_PREFIX}-${id}"
  
  local image; image=$(build_proxy_image 2>&1 | tail -1) || return 1
  [[ -z "$image" || "$image" != *":"* ]] && { echo "❌ Не получено имя образа" >&2; return 1; }

  echo "📦 Запускаем $container_name (Fake TLS, --network=host)..." >&2

  # Fake TLS ТРЕБУЕТ host network для корректной имитации TLS handshake
  docker run -d \
    --name "$container_name" \
    --restart unless-stopped \
    --network=host \
    -v "$config_file:/home/tgproxy/config.py:ro" \
    -v "$proxy_script:/home/tgproxy/mtprotoproxy.py:ro" \
    -v /etc/localtime:/etc/localtime:ro \
    --log-driver json-file \
    --log-opt max-size=10m \
    --log-opt max-file=10 \
    "$image" \
    python3 /home/tgproxy/mtprotoproxy.py /home/tgproxy/config.py

  return $?
}

# ==================== ВСПОМОГАТЕЛЬНЫЕ ====================

find_free_port() {
  local port="${1:-$DEFAULT_PORT}"
  local attempts=0
  while (( attempts < 1000 )); do
    if ! ss -tlnp 2>/dev/null | grep -qE ":[[:space:]]*$port[[:space:]]" && \
       ! docker ps --format '{{.Ports}}' 2>/dev/null | grep -qE "(0\.0\.0\.0|:::)$port->"; then
      echo "$port"; return 0
    fi
    ((port++)); ((attempts++)); ((port > 65535)) && port=1
  done
  echo "❌ Нет свободных портов" >&2; return 1
}

cleanup_missing_meta() {
  for dir in "$BASE_DIR"/*/; do
    [[ -d "$dir" ]] || continue
    local id; id=$(basename "$dir")
    if load_proxy_meta "$id" 2>/dev/null; then
      local container="${CONTAINER_NAME:-}"
      [[ -n "$container" ]] && ! docker inspect "$container" >/dev/null 2>&1 && rm -rf "$dir"
    else
      rm -rf "$dir"
    fi
  done
}

get_all_proxy_ids() {
  for dir in "$BASE_DIR"/*/; do [[ -d "$dir" ]] && basename "$dir"; done 2>/dev/null | sort
}

get_active_proxy_ids() {
  for id in $(get_all_proxy_ids); do
    load_proxy_meta "$id" 2>/dev/null || continue
    local container="${CONTAINER_NAME:-}"
    [[ -n "$container" ]] && docker ps --format '{{.Names}}' 2>/dev/null | grep -Fxq "$container" && echo "$id"
  done
}

# ==================== UI ====================

print_header() {
  clear
  echo "🚀 Менеджер MTProto Proxy (Fake TLS only)"
  echo "==========================================="
  echo "🔒 Режим: ee (Fake TLS) — максимальная защита от DPI"
  echo
}

print_main_menu() {
  echo "   1) ➕ Создать прокси (Fake TLS)"
  echo "   2) 📋 Список прокси"
  echo "   3) 📊 Статус + ссылка"
  echo "   4) 🗑️  Удалить"
  echo "   5) 📋 Логи"
  echo "   6) ♻️  Перезагрузить конфиг"
  echo "   0) 🚪 Выход"
  echo
}

pause() { echo; read -rp "Нажми Enter..."; echo; }

# ==================== CREATE PROXY (только ee) ====================

create_proxy() {
  print_header
  echo "➕ Создание прокси (режим: Fake TLS / ee)"
  echo "=========================================="

  local id="" name="" port="" secret="" tls_domain="$DEFAULT_TLS_DOMAIN"
  local ip="" container="" custom_name="" custom_port="" custom_domain=""

  clone_proxy_source || { echo "❌ Ошибка клонирования" >&2; pause; return; }
  id=$(generate_proxy_id)

  read -rp "Название (Enter = auto): " custom_name
  name="${custom_name:-proxy-$id}"

  read -rp "Порт (Enter = $DEFAULT_PORT): " custom_port
  if [[ -z "$custom_port" ]]; then
    port=$(find_free_port "$DEFAULT_PORT") || { pause; return; }
  else
    if ! [[ "$custom_port" =~ ^[0-9]+$ ]] || (( custom_port < 1 || custom_port > 65535 )); then
      echo "❌ Некорректный порт" >&2; pause; return
    fi
    if ss -tlnp 2>/dev/null | grep -qE ":[[:space:]]*$custom_port[[:space:]]"; then
      echo "❌ Порт занят" >&2; pause; return
    fi
    port="$custom_port"
  fi

  echo; echo "🌐 Домен для маскировки под HTTPS:"
  echo "   (трафик 'плохих' клиентов будет проксироваться сюда)"
  echo "   Рекомендуемые: cloudflare.com, github.com, microsoft.com"
  read -rp "Домен (Enter = $DEFAULT_TLS_DOMAIN): " custom_domain
  tls_domain="${custom_domain:-$DEFAULT_TLS_DOMAIN}"

  # Генерация ee-secret
  secret=$(generate_ee_secret "$tls_domain")
  local base_secret; base_secret=$(extract_base_from_ee "$secret")
  [[ -z "$base_secret" ]] && base_secret=$(generate_secret_hex)

  ip=$(get_public_ip)

  echo; echo "📋 Параметры:"
  echo "  Name: $name"
  echo "  Port: $port"
  echo "  Mode: Fake TLS (ee)"
  echo "  Domain: $tls_domain"
  echo "  Secret: $secret"
  echo "  IP: ${ip:-не определён}"
  echo

  read -rp "Запустить? [Y/n]: " confirm
  [[ ! "$confirm" =~ ^[Yy]$ && -n "$confirm" ]] && { echo "Отменено"; pause; return; }

  echo "⚙️  Генерируем config..." >&2
  generate_config_py "$id" "$port" "$base_secret" "$tls_domain"

  echo "🚀 Запускаем Docker..." >&2
  if run_proxy_container "$id" "$name" "$port" "$secret" "$tls_domain"; then
    save_proxy_meta "$id" "$name" "$port" "$secret" "$ip" "${CONTAINER_PREFIX}-${id}" "$tls_domain"
    
    echo; echo "✅ Прокси запущен!"
    echo "================================"
    echo "ID: $id | Container: ${CONTAINER_PREFIX}-${id}"
    echo "Port: $port | Domain: $tls_domain"
    echo
    if [[ -n "$ip" ]]; then
      echo "🔗 Ссылка для Telegram (Fake TLS):"
      echo "tg://proxy?server=$ip&port=$port&secret=$secret"
      echo ""
      echo "💡 Добавьте в Telegram:"
      echo "   Settings → Data and Storage → Proxy → Add Proxy"
    else
      echo "⚠️  Не удалось определить внешний IP"
      echo "   Укажите вручную при подключении"
    fi
    echo "================================"
  else
    echo "❌ Ошибка запуска" >&2
    docker logs "${CONTAINER_PREFIX}-${id}" 2>&1 | tail -20
  fi
  pause
}

# ==================== ОСТАЛЬНЫЕ ФУНКЦИИ ====================

show_proxy_list() {
  local ids; ids=$(get_all_proxy_ids)
  [[ -z "$ids" ]] && { echo "Прокси нет."; return 1; }
  echo "📋 Список (все — Fake TLS):"; echo "================================"
  local i=1
  while read -r id; do
    [[ -n "$id" ]] || continue
    load_proxy_meta "$id" 2>/dev/null || continue
    local container="${CONTAINER_NAME:-}" status="🔴 missing"
    [[ -n "$container" ]] && docker ps --format '{{.Names}}' 2>/dev/null | grep -Fxq "$container" && status="🟢 active"
    [[ -n "$container" ]] && ! docker ps --format '{{.Names}}' 2>/dev/null | grep -Fxq "$container" && docker inspect "$container" >/dev/null 2>&1 && status="🟡 stopped"
    printf "[%d] %-15s port=%-6s domain=%-20s %s\n" "$i" "${NAME:0:15}" "$PORT" "${TLS_DOMAIN:-$DEFAULT_TLS_DOMAIN}" "$status"
    ((i++))
  done <<< "$ids"
  echo "================================"
}

list_proxies() { print_header; echo "📋 Список"; echo "================================"; cleanup_missing_meta; show_proxy_list; pause; }

select_active_proxy() {
  local -a ids=(); local id
  while read -r id; do [[ -n "$id" ]] && ids+=("$id"); done < <(get_active_proxy_ids)
  [[ ${#ids[@]} -eq 0 ]] && { echo "Активных нет."; return 1; }
  echo "🔍 Активные:"; echo "================================"
  local i=1
  for id in "${ids[@]}"; do
    load_proxy_meta "$id" 2>/dev/null && printf "[%d] %-15s port=%s domain=%s\n" "$i" "${NAME:0:15}" "$PORT" "${TLS_DOMAIN:-$DEFAULT_TLS_DOMAIN}" && ((i++))
  done
  echo "================================"; echo
  read -rp "Номер: " sel
  [[ ! "$sel" =~ ^[0-9]+$ || sel -lt 1 || sel -gt ${#ids[@]} ]] && { echo "Некорректно"; return 1; }
  SELECTED_PROXY_ID="${ids[$((sel-1))]}"; return 0
}

proxy_status_and_link() {
  print_header; echo "📊 Статус + ссылка"; echo "================================"
  select_active_proxy || { pause; return; }
  load_proxy_meta "$SELECTED_PROXY_ID" 2>/dev/null || { echo "Ошибка"; pause; return; }
  local running="нет" container="${CONTAINER_NAME:-}"
  [[ -n "$container" ]] && docker ps --format '{{.Names}}' 2>/dev/null | grep -Fxq "$container" && running="да 🟢"
  local ip="${IP:-$(get_public_ip)}"
  echo "Name: $NAME | Port: $PORT | Domain: ${TLS_DOMAIN:-$DEFAULT_TLS_DOMAIN}"
  echo "Status: $running"
  echo "Secret: $SECRET"
  [[ -n "$ip" ]] && echo "🔗 tg://proxy?server=$ip&port=$PORT&secret=$SECRET" || echo "⚠️  IP не определён"
  echo "================================"; pause
}

delete_proxy() {
  print_header; echo "🗑️  Удаление"; echo "================================"
  select_active_proxy || { pause; return; }
  load_proxy_meta "$SELECTED_PROXY_ID" 2>/dev/null || { pause; return; }
  echo "Удалить: $NAME (port=$PORT)?"; read -rp "[y/N]: " c
  [[ ! "$c" =~ ^[Yy]$ ]] && { echo "Отменено"; pause; return; }
  docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
  rm -rf "$(proxy_dir_by_id "$SELECTED_PROXY_ID")"
  echo "✅ Удалено"; pause
}

show_proxy_logs() {
  print_header; echo "📋 Логи"; echo "================================"
  select_active_proxy || { pause; return; }
  load_proxy_meta "$SELECTED_PROXY_ID" 2>/dev/null || { pause; return; }
  docker logs --tail 100 "${CONTAINER_NAME:-}" 2>&1 || echo "❌ Ошибка"
  pause
}

reload_proxy_config() {
  print_header; echo "♻️  Перезагрузка конфига"; echo "================================"
  select_active_proxy || { pause; return; }
  load_proxy_meta "$SELECTED_PROXY_ID" 2>/dev/null || { pause; return; }
  docker kill -s SIGUSR2 "${CONTAINER_NAME:-}" 2>/dev/null && echo "✅ Сигнал отправлен" || echo "❌ Ошибка"
  pause
}


# ==================== ГЛАВНЫЙ ЦИКЛ ====================

main_loop() {
  while true; do
    cleanup_missing_meta; print_header; print_main_menu
    read -rp "Выбери: " ch; echo
    case "$ch" in
      1) create_proxy ;;
      2) list_proxies ;;
      3) proxy_status_and_link ;;
      4) delete_proxy ;;
      5) show_proxy_logs ;;
      6) reload_proxy_config ;;
      0) echo "👋 Выход."; exit 0 ;;
      *) echo "❌ Некорректно"; pause ;;
    esac
  done
}

main() {
  require_root; check_dependencies
  [[ ! -f "$PROXY_DIR/mtprotoproxy.py" ]] && { echo "📥 Клонируем..."; clone_proxy_source || exit 1; }
  docker info >/dev/null 2>&1 || { echo "❌ Docker не работает"; exit 1; }
  echo "✅ Готово. Запускаем меню..."; sleep 1; main_loop
}

main "$@"
