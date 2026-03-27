# mtproto_faketls

брал код отсюда и переделывал https://github.com/fastbrains13/MTProto-with-fake-tls

```bash
#!/bin/bash

CONTAINER_NAME="mtproto-proxy"
PORT="8443"

echo "🚀 Настройка MTProto proxy"
echo "=============================="

# Генерация секрета (обычный, без ee)
SECRET=$(openssl rand -hex 16)

echo "🔑 SECRET: $SECRET"

# Получаем IPv4 (ВАЖНО!)
IP=$(curl -4 -s ifconfig.me)

echo "🌐 IP: $IP"

# Удаляем старый контейнер
echo "🧹 Удаляем старый контейнер..."
docker rm -f $CONTAINER_NAME >/dev/null 2>&1

# Запуск нового
echo "📦 Запускаем новый контейнер..."
docker run -d \
  --name $CONTAINER_NAME \
  --restart unless-stopped \
  -p $PORT:443 \
  -e SECRET="$SECRET" \
  telegrammessenger/proxy >/dev/null

sleep 2

# Проверка
if docker ps | grep -q $CONTAINER_NAME; then
  echo ""
  echo "✅ ПРОКСИ ЗАПУЩЕН"
  echo "=============================="
  echo "IP: $IP"
  echo "PORT: $PORT"
  echo "SECRET: $SECRET"
  echo ""
  echo "🔗 ССЫЛКА:"
  echo "tg://proxy?server=$IP&port=$PORT&secret=$SECRET"
  echo "=============================="
else
  echo "❌ Ошибка запуска"
  docker logs $CONTAINER_NAME
fi
```
