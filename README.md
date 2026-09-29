# zabbix-agent-install

Установка Zabbix-агента на **Debian 10 / 11 / 12 / 13** и **Ubuntu 18.04 / 20.04 / 22.04 / 24.04 / 26.04** одной командой, с автоматической регистрацией хоста в Zabbix.

- репозиторий Zabbix 7.4, `zabbix-agent2` (или классический `zabbix-agent` с ключом `-1`);
- только активные проверки — входящий порт 10050 открывать не нужно, агенту нужен лишь исходящий доступ к серверу на 10051;
- трафик шифруется PSK, хост появляется в Zabbix сам через авторегистрацию;
- на Debian 10 при необходимости переключает apt на `archive.debian.org`;
- можно запускать повторно — просто обновит настройки.

## Самый простой способ — секретные ссылки

На своём веб-сервере с HTTPS один раз запускается `publish.sh` — он кладёт в `/i/` копии
установщика с уже вшитым PSK, по одной на клиента:

```bash
curl -fsSL https://raw.githubusercontent.com/glukogenerator-hue/zabbix-agent-install/main/publish.sh \
  | sudo PSK_KEY=<PSK> bash -s -- -u https://zbx.example.com aniks 3df sv
```

Он выведет ссылки вида `https://zbx.example.com/i/aniks-k3j9x0q2zp`. На хосте:

```bash
curl -fsSL https://zbx.example.com/i/aniks-k3j9x0q2zp | sudo bash
```

— ничего вводить не нужно, хост получает метку `client=aniks` и попадает в группу клиента.

- `publish.sh` без аргументов — пересобрать скрипты из свежего `install.sh`;
- `publish.sh aniks` — добавить клиента; `-r aniks` — перевыпустить ссылку; `-d aniks` — удалить; `-l` — список;
- ссылки хранятся в `/etc/zbx-install/links`, PSK — в `/etc/zbx-install/psk` (только root);
- ссылка = пароль: в ней PSK. Утекла — `publish.sh -r <клиент>`.

## Запуск напрямую с GitHub

От root:

```bash
curl -fsSL https://raw.githubusercontent.com/glukogenerator-hue/zabbix-agent-install/main/install.sh | bash
```

или, если нет `curl`:

```bash
wget -qO- https://raw.githubusercontent.com/glukogenerator-hue/zabbix-agent-install/main/install.sh | bash
```

Скрипт спросит PSK с клавиатуры. Чтобы запустить без вопросов, передайте ключ сразу (он при этом попадёт в history):

```bash
curl -fsSL https://raw.githubusercontent.com/glukogenerator-hue/zabbix-agent-install/main/install.sh | bash -s -- -k <PSK>
```

## Параметры

| Ключ | Что делает | По умолчанию |
|---|---|---|
| `-k PSK` | PSK авторегистрации (hex) | переменная `PSK_KEY` или запрос |
| `-s SERVER` | адрес сервера или прокси (`host` или `host:port`) | из зашифрованного конфига |
| `-n NAME` | имя хоста в Zabbix | `hostname -f` |
| `-m "TEXT"` | дополнительный текст в HostMetadata (дописывается к метке клиента), напр. `role=db` | — |
| `-1` | ставить `zabbix-agent` вместо `zabbix-agent2` | — |
| `-h` | справка | — |

Пример: через прокси, со своим именем и меткой клиента:

```bash
curl -fsSL https://raw.githubusercontent.com/glukogenerator-hue/zabbix-agent-install/main/install.sh \
  | bash -s -- -s 10.0.0.5 -n web01.client -m "client=acme"
```

## Адрес сервера

Адрес Zabbix-сервера и PSK identity в скрипте не хранятся открытым текстом — они зашифрованы
(AES-256-CBC, PBKDF2, 200 000 итераций) тем же PSK, который вводится при запуске.
Без ключа из репозитория их не достать. Перешифровать под другой сервер:

```bash
printf '%s' 'zabbix.example.com;my-identity' \
  | P=<PSK> openssl enc -aes-256-cbc -pbkdf2 -iter 200000 -salt -a -A -pass env:P
```

и вставить результат в `ENC_CFG` в `install.sh`.

## Что настраивается на хосте

`/etc/zabbix/zabbix_agent2.conf` (или `zabbix_agentd.conf`) — оригинал сохраняется рядом как `.orig`:

```
Server=<SERVER>
ServerActive=<SERVER>
Hostname=<NAME>
HostMetadata=linux-agent <debianN|ubuntuXX.YY> <arch> [TEXT]
TLSConnect=psk
TLSAccept=psk
TLSPSKIdentity=<identity>
TLSPSKFile=/etc/zabbix/zabbix_agent.psk
```

## Сторона Zabbix

На сервере должно быть:
- в *Administration → General → Autoregistration* разрешён PSK с тем же identity и ключом;
- action авторегистрации с условием «Host metadata contains `linux-agent`» (добавить хост, группа, шаблон *Linux by Zabbix agent active*).
