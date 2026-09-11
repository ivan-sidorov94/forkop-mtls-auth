# Forkop DoH + Nginx + AdGuard Home + mTLS

[English version](README.md)

Эта инструкция создаёт частный DNS-over-HTTPS сервер для роутера OpenWrt.
Запросы принимаются только от роутеров с клиентским сертификатом, выданным
серверным центром сертификации.

> [!WARNING]
> Проект меняет DNS и TLS-настройки роутера и сервера. Используйте его только
> на оборудовании, которым управляете, не копируйте закрытый ключ CA с сервера
> и заранее прочитайте раздел об удалении mTLS.

```text
Forkop на OpenWrt → mTLS DoH → Nginx :443 → AdGuard Home :3001
```

Nginx принимает публичный HTTPS и проверяет сертификат клиента. AdGuard Home
доступен только локально на сервере и не публикуется в интернет.

## Состав репозитория

| Файл | Назначение |
| --- | --- |
| `forkop-doh-server.sh` | Интерактивная установка сервера Debian/Ubuntu и управление сертификатами. |
| `forkop-mtls-patch.sh` | Интерактивная настройка mTLS для Forkop на OpenWrt. |
| `forkop-mtls-reset.sh` | Откат mTLS-настроек на OpenWrt. |
| `AdGuardHome.yaml.example` | Минимальный шаблон конфигурации AdGuard Home. |
| `README.md` | Полная английская версия инструкции. |

## Быстрый старт

1. Создайте DNS-запись, например `dns.example.net`, для нового сервера
   Debian/Ubuntu и откройте TCP-порты 80 и 443.
2. Скопируйте этот репозиторий на сервер, запустите от `root`
   `./forkop-doh-server.sh` и выберите пункт `1`.
3. Когда установщик приостановится, положите YAML AdGuard Home в
   `/opt/AdGuardHome/AdGuardHome.yaml`.
4. Выпустите сертификат роутера через пункт меню `2`, затем запустите
   `forkop-mtls-patch.sh` на OpenWrt.

Подробные шаги, проверки, отзыв сертификатов и откат находятся ниже.

## Что потребуется

- Новый сервер Debian или Ubuntu с systemd.
- Публичный IP и открытые TCP-порты 80 и 443.
- Домен, например `dns.example.net`, с A/AAAA-записью на IP сервера.
- Роутер OpenWrt с уже установленным Forkop.
- Доступ `root` по SSH к серверу и роутеру.

DNS-запись домена должна быть создана до запуска серверного скрипта: это
нужно Let’s Encrypt для выпуска сертификата.

## 1. Подготовить файлы

Скопируйте на сервер в один каталог, например `/root/forkop-doh/`:

```text
forkop-doh-server.sh
forkop-mtls-patch.sh
forkop-mtls-reset.sh
AdGuardHome.yaml.example
```

`AdGuardHome.yaml.example` — минимальный безопасный шаблон. Можно заменить
его собственным рабочим `AdGuardHome.yaml`: скрипт его не меняет.

## 2. Установить сервер

На сервере выполните только:

```bash
cd /root/forkop-doh
chmod 700 forkop-doh-server.sh
./forkop-doh-server.sh
```

В меню выберите `1`. Скрипт спросит:

```text
DNS domain: dns.example.net
DoH path: /api/v1/router-doh
Email for Let's Encrypt: admin@example.net
```

Укажите свой домен и собственный URL-путь. Путь должен начинаться с `/`.
Выберите достаточно случайное значение, например `/api/v1/2d0e5f8a`.

Скрипт сам устанавливает Nginx, Certbot, OpenSSL и AdGuard Home. После
загрузки AdGuard Home он приостановится. В другой SSH-сессии положите свой
YAML-конфиг прямо в каталог установленного AdGuard Home:

```bash
cp /root/forkop-doh/AdGuardHome.yaml.example /opt/AdGuardHome/AdGuardHome.yaml
chmod 600 /opt/AdGuardHome/AdGuardHome.yaml
```

Вернитесь в первую сессию и нажмите Enter. Скрипт продолжит установку.

Он создаст:

```text
/etc/nginx/sites-available/dns.example.net.conf
/etc/nginx/sites-enabled/dns.example.net.conf
/etc/forkop-doh/pki/             # CA и его закрытый ключ
/etc/forkop-doh/clients/         # клиентские сертификаты роутеров
/opt/AdGuardHome/                # бинарник, YAML и рабочие данные AdGuard
```

Certbot автоматически продлевает публичный сертификат Let’s Encrypt и после
успешного продления перезагружает Nginx. Не закрывайте порт 80 и не удаляйте
DNS-запись домена.

При открытии корня домена в браузере Nginx покажет нейтральную страницу-
заглушку ShareFlow. Она находится в `/var/www/ВАШ_ДОМЕН/index.html`. Это
только интерфейс: файлы не принимаются и не отправляются на сервер.

На уже настроенном сервере запустите серверный скрипт и выберите пункт `5`,
чтобы добавить или обновить Nginx-конфиг и страницу-заглушку.

Если установка оборвалась, снова запустите скрипт и выберите `1`: он
продолжит незавершённую установку.

Админ-панель AdGuard Home снаружи недоступна. Для доступа с компьютера
администратора создайте SSH-туннель:

```bash
ssh -L 3001:127.0.0.1:3001 root@SERVER_IP
```

После этого откройте на своём компьютере `http://127.0.0.1:3001`.

## 3. Выпустить сертификат для роутера

На сервере снова запустите:

```bash
./forkop-doh-server.sh
```

Выберите `2`, затем укажите уникальное имя, например `openwrt-home`.
Сертификат и ключ появятся здесь:

```text
/etc/forkop-doh/clients/openwrt-home/client.crt
/etc/forkop-doh/clients/openwrt-home/client.key
```

Передайте их на роутер, заменив `ROUTER_IP` и имя клиента:

```bash
ssh root@ROUTER_IP 'mkdir -p /etc/forkop/dns && chmod 700 /etc/forkop/dns'
scp /etc/forkop-doh/clients/openwrt-home/client.crt root@ROUTER_IP:/etc/forkop/dns/client.crt
scp /etc/forkop-doh/clients/openwrt-home/client.key root@ROUTER_IP:/etc/forkop/dns/client.key
ssh root@ROUTER_IP 'chmod 644 /etc/forkop/dns/client.crt && chmod 600 /etc/forkop/dns/client.key'
scp forkop-mtls-patch.sh root@ROUTER_IP:/root/forkop-mtls-patch.sh
```

Закрытый ключ CA `/etc/forkop-doh/pki/private/ca.key` никогда не копируйте с
сервера.

## 4. Настроить Forkop на роутере

На роутере:

```sh
chmod 700 /root/forkop-mtls-patch.sh
/root/forkop-mtls-patch.sh
```

Введите те же значения домена и DoH-пути, что были указаны на сервере:

```text
DNS domain: dns.example.net
DoH path: /api/v1/router-doh
Client certificate path: /etc/forkop/dns/client.crt
Client private-key path: /etc/forkop/dns/client.key
```

Скрипт добавляет mTLS DoH первым в список `dns_server`, а все прежние DNS
оставляет после него в том же порядке. Он не удаляет существующие DNS.

Ограничение Forkop: весь список `dns_server` использует один тип протокола.
Поэтому прежний `dns_type` должен быть `doh`. При `udp` или `dot` скрипт
остановится до изменения настроек — это защищает исходную конфигурацию.

Скрипт применяет патч `dns.uc`, сохраняет резервную копию и перезагружает
Forkop. Дополнительные пакеты OpenWrt не устанавливаются.

## 5. Проверить работу

На сервере:

```bash
systemctl status nginx adguardhome --no-pager
nginx -t
```

На роутере:

```sh
uci show forkop.settings | grep -E 'dns_(server|type|mtls)'
logread | grep -Ei 'forkop|sing-box|dns|tls' | tail -30
```

В списке `dns_server` новый URL должен быть первым и не содержать лишних
одинарных кавычек. При необходимости достаточно повторно запустить
`/root/forkop-mtls-patch.sh` с теми же данными: он корректно пересоберёт
список.

## 6. Добавить, отозвать или посмотреть сертификаты

На сервере запустите:

```bash
./forkop-doh-server.sh
```

Используйте пункты меню:

```text
2 — выпустить сертификат нового роутера;
3 — отозвать сертификат роутера;
4 — показать список сертификатов.
```

После отзыва скрипт обновляет CRL и перезагружает Nginx. Отозванный роутер
сразу теряет доступ к DoH.

## 7. Удалить mTLS с роутера

Чтобы вернуть старую конфигурацию Forkop перед новым тестом, передайте на
роутер `forkop-mtls-reset.sh` и выполните:

```sh
chmod 700 /root/forkop-mtls-reset.sh
/root/forkop-mtls-reset.sh
```

Введите `RESET` для подтверждения. Скрипт восстанавливает сохранённый
непропатченный `dns.uc`, удаляет только mTLS-настройки, сертификаты и старые
файлы патча; сам пакет Forkop остаётся установленным.

## Обновление Forkop

Обновление Forkop может заменить `dns.uc`. После обновления снова выполните
`/root/forkop-mtls-patch.sh`. Если новая версия Forkop несовместима с патчем,
скрипт остановится без изменения файла.
