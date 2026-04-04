# mtproto вайбкод

Для установки арендуем vps сервер с минимальным конфигом, ставил на timeweb cloud. (реф ссылка https://timeweb.cloud/?i=126855)

Логинимся по ssh на арендованный сервер.

Перед запуском устанавливаем выполняя команду apt install docker.io

curl -Ls -O https://raw.githubusercontent.com/puzzle977/mtproto_faketls/refs/heads/main/start-mtproxy.sh

chmod +x start-mtproxy.sh

sudo ./start-mtproxy.sh


Протестировано на ubuntu 22
