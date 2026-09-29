#!/usr/bin/env bash
# =============================================================================
#  Публикация установщика Zabbix-агента по секретным ссылкам.
#  Запускать на веб-сервере (Apache/nginx) от root. Для каждого клиента создаётся
#  своя ссылка: в скрипт по ней уже вшиты PSK и метка client=<имя>, поэтому на
#  хосте достаточно одной команды без ввода ключа:
#     curl -fsSL https://<сервер>/i/<токен> | sudo bash
#
#  publish.sh [-u BASE_URL] [-w WEBROOT] [-r] [-l] [client ...]
#     client       метка клиента (a-z, 0-9, '-'), напр. aniks 3df sv
#     -u BASE_URL  внешний адрес сайта, напр. https://zbx.example.com (запоминается)
#     -w WEBROOT   корень сайта (по умолч. /var/www/html, запоминается)
#     -r           перевыпустить ссылки указанных клиентов (без клиентов — все)
#     -d           удалить ссылки указанных клиентов
#     -l           только показать текущие ссылки
#  PSK: переменная PSK_KEY, файл /etc/zbx-install/psk или запрос с клавиатуры.
#  Повторный запуск без аргументов пересобирает скрипты из свежего install.sh.
# =============================================================================
set -euo pipefail

SRC_URL="${SRC_URL:-https://raw.githubusercontent.com/glukogenerator-hue/zabbix-agent-install/main/install.sh}"
CONF_DIR=/etc/zbx-install
LINKS="$CONF_DIR/links"        # строки: <client|-> <token>
PSK_STORE="$CONF_DIR/psk"
SETTINGS="$CONF_DIR/settings"
SUBDIR="i"

c_g=$'\e[32m'; c_y=$'\e[33m'; c_r=$'\e[31m'; c_0=$'\e[0m'
log()  { echo "${c_g}[+]${c_0} $*"; }
warn() { echo "${c_y}[!]${c_0} $*" >&2; }
die()  { echo "${c_r}[x]${c_0} $*" >&2; exit 1; }
ask()  { local v; { read -r -p "$1" v < /dev/tty; } 2>/dev/tty || true; printf '%s' "$v"; }

main() {
[[ $EUID -eq 0 ]] || die "Запускать нужно от root"
for t in curl openssl sed awk; do command -v "$t" >/dev/null || die "Нужна утилита $t"; done
mkdir -p "$CONF_DIR"; chmod 700 "$CONF_DIR"

BASE_URL=""; WEBROOT=""
# shellcheck disable=SC1090
[[ -f "$SETTINGS" ]] && . "$SETTINGS"
ROTATE=0; DELETE=0; LIST=0
while getopts "u:w:rdlh" opt; do
  case "$opt" in
    u) BASE_URL="$OPTARG" ;;
    w) WEBROOT="$OPTARG" ;;
    r) ROTATE=1 ;;
    d) DELETE=1 ;;
    l) LIST=1 ;;
    *) sed -n '2,20p' "$0" 2>/dev/null | sed 's/^# \{0,1\}//'; exit 0 ;;
  esac
done
shift $((OPTIND - 1))

WEBROOT="${WEBROOT:-/var/www/html}"
if [[ -z "$BASE_URL" ]]; then
  BASE_URL="$(ask "Внешний адрес сайта [https://$(hostname -f)]: ")"
  BASE_URL="${BASE_URL:-https://$(hostname -f)}"
fi
BASE_URL="${BASE_URL%/}"
[[ "$BASE_URL" =~ ^https:// ]] || die "Нужен https:// — по ссылке передаётся PSK"
[[ -d "$WEBROOT" ]] || die "Нет каталога $WEBROOT (укажи -w)"
printf 'BASE_URL=%q\nWEBROOT=%q\n' "$BASE_URL" "$WEBROOT" > "$SETTINGS"

touch "$LINKS"; chmod 600 "$LINKS"
grep -q '^- ' "$LINKS" || echo "- $(gen_token)" >> "$LINKS"

if [[ $LIST -eq 1 ]]; then show_links; exit 0; fi

# --- PSK ---------------------------------------------------------------------
PSK="${PSK_KEY:-}"
[[ -z "$PSK" && -s "$PSK_STORE" ]] && PSK="$(cat "$PSK_STORE")"
[[ -n "$PSK" ]] || PSK="$(ask "PSK авторегистрации (hex): ")"
[[ "$PSK" =~ ^[0-9a-fA-F]{32,512}$ ]] || die "PSK должен быть hex-строкой"
( umask 077; printf '%s\n' "$PSK" > "$PSK_STORE" )

# --- клиенты -----------------------------------------------------------------
for c in "$@"; do
  [[ "$c" =~ ^[a-z0-9][a-z0-9-]{0,30}$ ]] || die "Плохое имя клиента: $c (только a-z, 0-9, -)"
  if [[ $DELETE -eq 1 || $ROTATE -eq 1 ]]; then
    awk -v c="$c" '$1 != c' "$LINKS" > "$LINKS.tmp" && cat "$LINKS.tmp" > "$LINKS" && rm -f "$LINKS.tmp"
  fi
  [[ $DELETE -eq 1 ]] && continue
  grep -q "^$c " "$LINKS" || echo "$c $c-$(gen_token)" >> "$LINKS"
done
if [[ $ROTATE -eq 1 && $# -eq 0 ]]; then
  awk '{ print $1 }' "$LINKS" > "$LINKS.tmp"; : > "$LINKS"
  while read -r c; do
    if [[ "$c" == "-" ]]; then echo "- $(gen_token)"; else echo "$c $c-$(gen_token)"; fi >> "$LINKS"
  done < "$LINKS.tmp"; rm -f "$LINKS.tmp"
fi

# --- свежий install.sh -------------------------------------------------------
tmp="$(mktemp)"; trap 'rm -f "$tmp" "$tmp.out"' EXIT
log "Скачиваю install.sh"
curl -fsSL --retry 3 -o "$tmp" "$SRC_URL" || die "Не удалось скачать $SRC_URL"
bash -n "$tmp" || die "install.sh с синтаксической ошибкой"
grep -q '^PSK_KEY="${PSK_KEY:-}"$' "$tmp" && grep -q '^EXTRA_META=""$' "$tmp" \
  || die "Формат install.sh изменился — нет строк для подстановки"
enc="$(sed -n 's/^ENC_CFG="\(.*\)"$/\1/p' "$tmp")"
cfg="$(printf '%s\n' "$enc" | P="$PSK" openssl enc -d -aes-256-cbc -pbkdf2 -iter 200000 -a -A -pass env:P 2>/dev/null || true)"
[[ "$cfg" == *";"* ]] || die "PSK не подходит к зашифрованному конфигу в install.sh"
log "PSK подходит, сервер Zabbix: ${cfg%%;*}"

# --- генерация ---------------------------------------------------------------
out="$WEBROOT/$SUBDIR"
mkdir -p "$out"; : > "$out/index.html"; chmod 755 "$out"; chmod 644 "$out/index.html"
tokens=" index.html "
while read -r c tok; do
  [[ -n "$tok" ]] || continue
  meta=""; [[ "$c" != "-" ]] && meta="client=$c"
  sed -e "s|^PSK_KEY=\"\${PSK_KEY:-}\"\$|PSK_KEY=\"\${PSK_KEY:-$PSK}\"|" \
      -e "s|^EXTRA_META=\"\"\$|EXTRA_META=\"$meta\"|" "$tmp" > "$tmp.out"
  grep -q "^PSK_KEY=\"\${PSK_KEY:-$PSK}\"\$" "$tmp.out" || die "Не удалось вшить PSK"
  install -m 644 "$tmp.out" "$out/$tok"
  tokens+="$tok "
done < "$LINKS"
# убираем ссылки, которых больше нет в списке
for f in "$out"/*; do
  [[ -f "$f" ]] || continue
  [[ "$tokens" == *" $(basename "$f") "* ]] || { rm -f "$f"; warn "Удалена старая ссылка $(basename "$f")"; }
done

check_tls
show_links
}

gen_token() { head -c 64 /dev/urandom | base64 | tr -dc 'a-z0-9' | head -c 10; }

show_links() {
  echo
  log "Ссылки (храни как пароль — в каждой вшит PSK):"
  while read -r c tok; do
    [[ -n "$tok" ]] || continue
    printf '  %-12s curl -fsSL %s/%s/%s | sudo bash\n' "${c/#-/(без клиента)}" "$BASE_URL" "$SUBDIR" "$tok"
  done < "$LINKS"
}

check_tls() {
  local host="${BASE_URL#https://}"; host="${host%%/*}"
  local port=443; [[ "$host" == *:* ]] && { port="${host##*:}"; host="${host%:*}"; }
  local tok; tok="$(awk '$1=="-"{print $2}' "$LINKS")"
  if curl -fsS --max-time 15 -o /dev/null "$BASE_URL/$SUBDIR/$tok" 2>/dev/null; then
    log "Ссылка открывается по HTTPS"
  else
    warn "curl не смог скачать $BASE_URL/$SUBDIR/$tok — проверь веб-сервер/сертификат"
  fi
  local n
  n="$(timeout 15 openssl s_client -connect "$host:$port" -servername "$host" -showcerts </dev/null 2>/dev/null | grep -c 'BEGIN CERTIFICATE' || true)"
  if [[ "${n:-0}" -le 1 ]]; then
    warn "Сервер отдаёт только свой сертификат без промежуточных — curl на Linux его не проверит."
    warn "Нужно указать полную цепочку (fullchain) в конфиге веб-сервера. Текущие настройки Apache:"
    grep -RhsE '^\s*SSLCertificate(Chain)?File' /etc/apache2/sites-enabled/ 2>/dev/null | sed 's/^/      /' >&2 || true
  elif [[ -r /etc/ssl/certs/ISRG_Root_X1.pem ]] \
       && timeout 15 openssl s_client -connect "$host:$port" -servername "$host" </dev/null 2>/dev/null | grep -q "O = Let's Encrypt" \
       && ! timeout 15 openssl s_client -connect "$host:$port" -servername "$host" \
        -CAfile /etc/ssl/certs/ISRG_Root_X1.pem -verify_return_error </dev/null >/dev/null 2>&1; then
    warn "Цепочка не сходится к ISRG Root X1 — на старых Debian (10/11) curl может не проверить сертификат."
  else
    log "Цепочка сертификатов в порядке"
  fi
}

main "$@"
