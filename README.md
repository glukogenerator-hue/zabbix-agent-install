# zabbix-agent-install

Установка Zabbix-агента на **Debian 10 / 11 / 12 / 13** одной командой, с автоматической регистрацией хоста в Zabbix.

- репозиторий Zabbix 7.4, `zabbix-agent2` (или классический `zabbix-agent` с ключом `-1`);
- только активные проверки — входящий порт 10050 открывать не нужно, агенту нужен лишь исходящий доступ к серверу на 10051;
- трафик шифруется PSK, хост появляется в Zabbix сам через авторегистрацию;
- на Debian 10 при необходимости переключает apt на `archive.debian.org`;
- можно запускать повторно — просто обновит настройки.

## Запуск

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
| `-m "TEXT"` | дополнительный текст в HostMetadata, напр. `client=acme` | — |
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
HostMetadata=linux-agent debian<N> <arch> [TEXT]
TLSConnect=psk
TLSAccept=psk
TLSPSKIdentity=<identity>
TLSPSKFile=/etc/zabbix/zabbix_agent.psk
```

## Сторона Zabbix

На сервере должно быть:
- в *Administration → General → Autoregistration* разрешён PSK с тем же identity и ключом;
- action авторегистрации с условием «Host metadata contains `linux-agent`» (добавить хост, группа, шаблон *Linux by Zabbix agent active*).
