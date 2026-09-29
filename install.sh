#!/usr/bin/env bash
# =============================================================================
#  Установка Zabbix-агента на Debian 10/11/12/13 с авторегистрацией в Zabbix
#  (Zabbix 7.4, zabbix-agent2, активные проверки, шифрование PSK).
#
#  Одной командой (от root):
#    curl -fsSL https://raw.githubusercontent.com/glukogenerator-hue/zabbix-agent-install/main/install.sh | bash
#    wget -qO- https://raw.githubusercontent.com/glukogenerator-hue/zabbix-agent-install/main/install.sh | bash
#  Без -k ключ будет запрошен с клавиатуры (не попадёт в history).
#
#  Ключи:
#    -k PSK      PSK авторегистрации (hex); иначе $PSK_KEY или запрос с клавиатуры
#    -s SERVER   сервер/прокси (host или host:port), по умолч. из зашифрованного конфига
#    -n NAME     имя хоста в Zabbix (по умолч. hostname -f)
#    -m TEXT     доп. текст в HostMetadata (напр. "client=acme role=db")
#    -1          классический zabbix-agent вместо zabbix-agent2
#    -h          справка
#
#  Скрипт идемпотентный — можно запускать повторно (обновит настройки).
# =============================================================================
set -euo pipefail

# --- Параметры по умолчанию (можно переопределить переменными окружения) ------
ZBX_SERVER="${ZBX_SERVER:-}"
ZBX_VERSION="${ZBX_VERSION:-7.4}"
PSK_IDENTITY="${PSK_IDENTITY:-}"
PSK_KEY="${PSK_KEY:-}"
# Адрес сервера и PSK identity зашифрованы (AES-256-CBC, PBKDF2, ключ = PSK):
#   printf '%s' 'server;identity' | P=<PSK> openssl enc -aes-256-cbc -pbkdf2 -iter 200000 -salt -a -A -pass env:P
ENC_CFG="U2FsdGVkX18/I3+E3ejpkhp1MeFd5k08/VOI9CY3rRlwpDVdVh7NxD21XAEchxx7M3JbA9M1YTj9X8r2RQK1ig=="
META_TAG="linux-agent"          # по этой строке сервер узнаёт хост при авторегистрации
HOST_NAME=""
EXTRA_META=""
FORCE_AGENT1=0

PSK_FILE="/etc/zabbix/zabbix_agent.psk"
MARK="# --- managed by zabbix-agent-install.sh ---"

# --- Вывод ---------------------------------------------------------------------
c_g=$'\e[32m'; c_y=$'\e[33m'; c_r=$'\e[31m'; c_0=$'\e[0m'
log()  { echo "${c_g}[+]${c_0} $*"; }
warn() { echo "${c_y}[!]${c_0} $*" >&2; }
die()  { echo "${c_r}[x]${c_0} $*" >&2; exit 1; }

# Расшифровка ENC_CFG ключом PSK -> ZBX_SERVER / PSK_IDENTITY (если не заданы явно)
CFG_OK=0
resolve_cfg() {
  [[ $CFG_OK -eq 1 ]] && return 0
  command -v openssl >/dev/null || return 1
  local cfg
  cfg="$(printf '%s\n' "$ENC_CFG" | ZBX_PSK_TMP="$PSK_KEY" openssl enc -d -aes-256-cbc \
          -pbkdf2 -iter 200000 -a -A -pass env:ZBX_PSK_TMP 2>/dev/null)" || cfg=""
  [[ "$cfg" =~ ^[A-Za-z0-9.:-]+\;[A-Za-z0-9._-]+$ ]] || die "Неверный PSK — не удалось расшифровать конфиг"
  [[ -n "$ZBX_SERVER" ]]   || ZBX_SERVER="${cfg%%;*}"
  [[ -n "$PSK_IDENTITY" ]] || PSK_IDENTITY="${cfg#*;}"
  CFG_OK=1
}

usage() {
  cat <<'EOF'
Установка Zabbix-агента (Debian 10-13) с авторегистрацией.

  install.sh [-k PSK] [-s SERVER] [-n NAME] [-m "TEXT"] [-1]

  -k PSK      PSK авторегистрации (hex); иначе $PSK_KEY или запрос с клавиатуры
  -s SERVER   сервер/прокси (host или host:port), по умолч. из зашифрованного конфига
  -n NAME     имя хоста в Zabbix (по умолч. hostname -f)
  -m TEXT     доп. текст в HostMetadata (напр. "client=acme role=db")
  -1          классический zabbix-agent вместо zabbix-agent2
EOF
  exit 0
}

# Всё тело — в функции: при запуске через "curl | bash" bash прочитает скрипт
# целиком до начала выполнения, и apt/dpkg не «съедят» остаток из stdin.
main() {
while getopts "k:s:n:m:1h" opt; do
  case "$opt" in
    k) PSK_KEY="$OPTARG" ;;
    s) ZBX_SERVER="$OPTARG" ;;
    n) HOST_NAME="$OPTARG" ;;
    m) EXTRA_META="$OPTARG" ;;
    1) FORCE_AGENT1=1 ;;
    h|*) usage ;;
  esac
done

[[ $EUID -eq 0 ]] || die "Запускать нужно от root (или через sudo)"
# PSK спрашиваем сразу, до долгой установки
if [[ -z "$PSK_KEY" ]]; then
  { { read -r -s -p "PSK авторегистрации (hex): " PSK_KEY < /dev/tty; echo >&2; } 2>/dev/tty; } 2>/dev/null || true
  [[ -n "$PSK_KEY" ]] || die "Не задан PSK: передай ключ -k <PSK> или переменную PSK_KEY"
fi
[[ "$PSK_KEY" =~ ^[0-9a-fA-F]{32,512}$ ]] || die "PSK должен быть hex-строкой (32+ символа)"
resolve_cfg || true   # если openssl ещё нет — расшифруем после его установки
[[ -r /etc/os-release ]] || die "Нет /etc/os-release — это точно Debian?"
# shellcheck disable=SC1091
. /etc/os-release
[[ "${ID:-}" == "debian" ]] || die "Поддерживается только Debian (найдено: ${ID:-?})"
DEB_VER="${VERSION_ID%%.*}"
DEB_CODENAME="${VERSION_CODENAME:-}"
case "$DEB_VER" in
  10|11|12|13) ;;
  *) die "Поддерживаются Debian 10–13 (найдено: ${VERSION_ID:-?})" ;;
esac
ARCH="$(dpkg --print-architecture)"
log "Debian ${DEB_VER} (${DEB_CODENAME:-?}), архитектура ${ARCH}"

export DEBIAN_FRONTEND=noninteractive
APT_OPTS=(-y -q -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)

# --- Debian 10: репозитории переехали на archive.debian.org ---------------------
fix_buster_sources() {
  warn "Debian 10 снят с поддержки — переключаю репозитории на archive.debian.org"
  local f
  for f in /etc/apt/sources.list /etc/apt/sources.list.d/*.list; do
    [[ -f "$f" ]] || continue
    grep -qE '^[[:space:]]*deb(-src)?[[:space:]].*buster' "$f" || continue
    [[ -f "$f.bak-zbx" ]] || cp -a "$f" "$f.bak-zbx"
    awk '
      /^[[:space:]]*deb(-src)?[[:space:]]/ && /buster/ {
        # находим поле с URL (после необязательных [опций]) и сьют за ним
        for (i = 2; i <= NF; i++) if ($i ~ /^(https?|ftp):\/\//) break
        # трогаем только зеркала Debian (…debian.org или путь /debian, /debian-security),
        # сторонние репозитории (docker и т.п.) оставляем как есть
        url = $i; host = url; sub(/^[a-z]+:\/\//, "", host); path = host
        sub(/\/.*/, "", host); sub(/^[^\/]*/, "", path)
        mirror = (host ~ /(^|\.)debian\.org$/) || (path ~ /^\/debian(-security)?\/?$/)
        if (mirror && i < NF && $(i+1) ~ /^buster/) {
          if ($(i+1) ~ /\/updates$/ || $(i+1) ~ /-security$/) {
            $i = "http://archive.debian.org/debian-security"; $(i+1) = "buster/updates"
          } else {
            $i = "http://archive.debian.org/debian"
          }
        }
      }
      { print }' "$f" > "$f.tmp-zbx" && mv "$f.tmp-zbx" "$f"
  done
  echo 'Acquire::Check-Valid-Until "false";' > /etc/apt/apt.conf.d/99archive-no-valid-until
}

apt_update() {
  if ! apt-get update -q; then
    if [[ "$DEB_VER" == "10" ]]; then
      fix_buster_sources
      apt-get update -q || die "apt-get update не прошёл даже с archive.debian.org — проверь /etc/apt/sources.list"
    else
      die "apt-get update завершился с ошибкой — проверь репозитории"
    fi
  fi
}

log "Обновляю список пакетов"
apt_update

# --- Утилиты для скачивания ------------------------------------------------------
if ! command -v wget >/dev/null && ! command -v curl >/dev/null; then
  apt-get install "${APT_OPTS[@]}" --no-install-recommends wget ca-certificates openssl
else
  apt-get install "${APT_OPTS[@]}" --no-install-recommends ca-certificates openssl >/dev/null
fi
resolve_cfg || die "openssl не установлен — не могу расшифровать конфиг"
fetch() {  # fetch URL FILE
  if command -v curl >/dev/null; then curl -fsSL --retry 3 -o "$2" "$1"
  else wget -q --tries=3 -O "$2" "$1"; fi
}

# --- Репозиторий Zabbix ----------------------------------------------------------
# Какие архитектуры есть в repo.zabbix.com для 7.4
repo_supported() {
  case "${DEB_VER}:${ARCH}" in
    10:amd64|10:i386|11:amd64|12:amd64|12:arm64|12:i386|13:amd64|13:arm64) return 0 ;;
    *) return 1 ;;
  esac
}

if repo_supported; then
  REL_DEB="zabbix-release_latest_${ZBX_VERSION}+debian${DEB_VER}_all.deb"
  REL_URL="https://repo.zabbix.com/zabbix/${ZBX_VERSION}/release/debian/pool/main/z/zabbix-release/${REL_DEB}"
  TMP_DEB="$(mktemp --suffix=.deb)"
  log "Подключаю репозиторий Zabbix ${ZBX_VERSION}"
  fetch "$REL_URL" "$TMP_DEB" || die "Не удалось скачать $REL_URL"
  dpkg -i "$TMP_DEB" >/dev/null
  rm -f "$TMP_DEB"
  apt_update
else
  warn "Для Debian ${DEB_VER}/${ARCH} нет пакетов в repo.zabbix.com — ставлю агент из репозитория Debian"
fi

# --- Выбор агента ----------------------------------------------------------------
has_candidate() { apt-cache policy "$1" 2>/dev/null | grep -q 'Candidate: [0-9]'; }

if [[ $FORCE_AGENT1 -eq 0 ]] && has_candidate zabbix-agent2; then
  PKG="zabbix-agent2"; SVC="zabbix-agent2"; CONF="/etc/zabbix/zabbix_agent2.conf"
  LOGF="/var/log/zabbix/zabbix_agent2.log"; OTHER_SVC="zabbix-agent"
elif has_candidate zabbix-agent; then
  PKG="zabbix-agent"; SVC="zabbix-agent"; CONF="/etc/zabbix/zabbix_agentd.conf"
  LOGF="/var/log/zabbix/zabbix_agentd.log"; OTHER_SVC="zabbix-agent2"
else
  die "Пакет zabbix-agent/zabbix-agent2 недоступен"
fi

log "Устанавливаю ${PKG}"
apt-get install "${APT_OPTS[@]}" --no-install-recommends "$PKG"
[[ -f "$CONF" ]] || die "Не найден конфиг $CONF"

# второй агент (если стоял) занимает порт 10050 — отключаем
if systemctl list-unit-files "${OTHER_SVC}.service" 2>/dev/null | grep -q "^${OTHER_SVC}.service"; then
  warn "Отключаю ${OTHER_SVC} (конфликтует с ${SVC} по порту 10050)"
  systemctl disable --now "$OTHER_SVC" >/dev/null 2>&1 || true
fi

# --- Имя хоста и метаданные ------------------------------------------------------
if [[ -z "$HOST_NAME" ]]; then
  HOST_NAME="$(hostname -f 2>/dev/null || true)"
  [[ -z "$HOST_NAME" || "$HOST_NAME" == localhost* ]] && HOST_NAME="$(hostname)"
fi
# Zabbix допускает в имени хоста: буквы, цифры, пробел, точку, дефис, подчёркивание
HOST_NAME="$(printf '%s' "$HOST_NAME" | tr -c 'A-Za-z0-9._ -' '_' | cut -c1-128)"
[[ -n "$HOST_NAME" ]] || die "Не удалось определить имя хоста — укажи его ключом -n"

META="${META_TAG} debian${DEB_VER} ${ARCH}${EXTRA_META:+ ${EXTRA_META}}"
META="${META:0:255}"

# --- PSK -------------------------------------------------------------------------
( umask 027; printf '%s\n' "$PSK_KEY" > "$PSK_FILE" )
chown root:zabbix "$PSK_FILE"
chmod 640 "$PSK_FILE"

# --- Конфиг агента ---------------------------------------------------------------
[[ -f "${CONF}.orig" ]] || cp -a "$CONF" "${CONF}.orig"
KEYS=(Server ServerActive Hostname HostnameItem HostMetadata HostMetadataItem
      TLSConnect TLSAccept TLSPSKIdentity TLSPSKFile)
for k in "${KEYS[@]}"; do
  sed -i -E "/^[[:space:]]*${k}[[:space:]]*=/d" "$CONF"
done
tmp_conf="$(mktemp)"
grep -vxF "$MARK" "$CONF" > "$tmp_conf" || true
cat "$tmp_conf" > "$CONF"; rm -f "$tmp_conf"
cat >> "$CONF" <<EOF
${MARK}
Server=${ZBX_SERVER}
ServerActive=${ZBX_SERVER}
Hostname=${HOST_NAME}
HostMetadata=${META}
TLSConnect=psk
TLSAccept=psk
TLSPSKIdentity=${PSK_IDENTITY}
TLSPSKFile=${PSK_FILE}
EOF

# --- Проверка доступности сервера ------------------------------------------------
first="${ZBX_SERVER%%[,;]*}"
if [[ "$first" == *:* ]]; then srv_host="${first%:*}"; srv_port="${first##*:}"; else srv_host="$first"; srv_port=10051; fi
if timeout 5 bash -c ">/dev/tcp/${srv_host}/${srv_port}" 2>/dev/null; then
  log "Сервер ${srv_host}:${srv_port} доступен"
else
  warn "Нет TCP-соединения с ${srv_host}:${srv_port} — проверь фаервол/исходящий доступ"
fi

# --- Запуск ----------------------------------------------------------------------
log_start=0
[[ -f "$LOGF" ]] && log_start="$(wc -l < "$LOGF")"
log "Перезапускаю ${SVC}"
systemctl enable "$SVC" >/dev/null 2>&1 || true
systemctl restart "$SVC"
sleep 5
if ! systemctl is-active --quiet "$SVC"; then
  journalctl -u "$SVC" -n 30 --no-pager >&2 || true
  die "${SVC} не запустился"
fi

# даём агенту время сходить на сервер и смотрим свежие строки лога
log "Жду первое обращение к серверу (~20 с)"
sleep 20
if [[ -f "$LOGF" ]]; then
  errs="$(tail -n +"$((log_start + 1))" "$LOGF" | grep -iE 'cannot|failed|error|rejected' || true)"
  if [[ -n "$errs" ]]; then
    warn "В логе агента есть ошибки:"
    printf '%s\n' "$errs" | tail -n 10 >&2
  fi
fi

echo
log "Готово."
echo "    Агент:        ${PKG} $(dpkg-query -W -f='${Version}' "$PKG" 2>/dev/null)"
echo "    Сервер:       ${ZBX_SERVER}"
echo "    Имя в Zabbix: ${HOST_NAME}"
echo "    Метаданные:   ${META}"
echo "    PSK identity: ${PSK_IDENTITY}"
echo "    Хост появится в Zabbix автоматически в течение ~1–2 минут."
}

main "$@" < /dev/null
