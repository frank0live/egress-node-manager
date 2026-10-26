#!/usr/bin/env bash
# egress-node-manager.sh
# one tor socks5 proxy per exit country, each its own systemd service.
# local proxies only, it never touches xray or any panel config.

set -Eeuo pipefail

NAME="egress-node-manager"
BASE="/etc/egress-nodes"
META_DIR="$BASE/nodes"
TORRCDIR="/etc/tor"
DATADIR="/var/lib/egress-nodes"
LOGDIR="/var/log/egress-nodes"
TRIES=8
WAIT=70
BASE_PORT=9053

# shown when onionoo can't be reached
FALLBACK="us fr nl tr ch se gb ca mx de"

red='\033[0;31m'
grn='\033[0;32m'
ylw='\033[1;33m'
blu='\033[0;34m'
rst='\033[0m'

say()  { echo -e "${blu}==>${rst} $*"; }
ok()   { echo -e "${grn}OK:${rst} $*"; }
warn() { echo -e "${ylw}WARN:${rst} $*"; }
die()  { echo -e "${red}ERROR:${rst} $*" >&2; exit "${2:-1}"; }

need_root() {
  [[ $EUID -eq 0 ]] || die "run as root, e.g. sudo bash $0"
}

usage() {
  cat <<USAGE
$NAME

Usage:
  $0 menu
  $0 add <cc> [port]
  $0 list
  $0 json <cc>
  $0 logs <cc>
  $0 test <cc>
  $0 restart <cc>
  $0 delete <cc>
  $0 upgrade
  $0 clean-db

Examples:
  $0 add tr 9053
  $0 test tr
  $0 json tr

Notes:
  - proxies listen on 127.0.0.1:<port> only, nothing is exposed
  - xray / panels are not touched, you wire the socks outbound yourself
  - cc is a two letter country code, upper or lower case
  - the menu lists live exit countries from onionoo
  - tor only carries tcp, don't point udp/quic at these ports
USAGE
}

# lowercase, letters only, must be two chars
cc_lower() {
  local cc="${1:-}"
  cc="$(echo "$cc" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z')"
  [[ $cc =~ ^[a-z]{2}$ ]] || die "bad country code '${1:-empty}', use two letters like tr, de, nl"
  echo "$cc"
}

cc_upper() {
  echo "$1" | tr '[:lower:]' '[:upper:]'
}

port_ok() {
  local p="${1:-}"
  [[ $p =~ ^[0-9]+$ ]] && (( p >= 1024 && p <= 65535 )) \
    || die "bad port '$p', pick something 1024-65535"
  echo "$p"
}

svc_of()   { echo "tor-egress-$(cc_lower "$1")"; }
meta_of()  { echo "$META_DIR/$(cc_lower "$1").env"; }
torrc_of() { echo "$TORRCDIR/tor-egress-$(cc_lower "$1").torrc"; }

# loads COUNTRY_CODE, SOCKS_PORT, SERVICE_NAME, TORRC_FILE, DATA_DIR, LOG_FILE
load_meta() {
  local cc mf
  cc="$(cc_lower "$1")"
  mf="$(meta_of "$cc")"
  [[ -f $mf ]] || die "no node '$cc' yet, add it first"
  # shellcheck disable=SC1090
  source "$mf"
  : "${COUNTRY_CODE:?broken meta file}"
  : "${SOCKS_PORT:?broken meta file}"
}

ensure_deps() {
  if command -v tor >/dev/null 2>&1 && command -v curl >/dev/null 2>&1 \
    && command -v jq >/dev/null 2>&1 && command -v ss >/dev/null 2>&1 \
    && command -v nc >/dev/null 2>&1 \
    && [[ -r /usr/share/iso-codes/json/iso_3166-1.json ]]; then
    return 0
  fi
  say "installing packages"
  if command -v apt-get >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y tor curl jq ca-certificates iproute2 netcat-openbsd iso-codes
  else
    die "only debian/ubuntu with apt are supported"
  fi
}

tor_account() {
  if id debian-tor >/dev/null 2>&1; then
    echo debian-tor
  elif id tor >/dev/null 2>&1; then
    echo tor
  else
    echo root
  fi
}

# true if the port is held by something that isn't our own torrc
port_taken() {
  local port="$1" torrc="$2" pids pid cmd taken=0
  ss -ltn 2>/dev/null | grep -qE "[:.]${port}[[:space:]]" || return 1
  pids="$(ss -ltnp 2>/dev/null | grep -E "[:.]${port}[[:space:]]" | grep -oE 'pid=[0-9]+' | cut -d= -f2 | sort -u || true)"
  [[ -z $pids ]] && return 0
  for pid in $pids; do
    cmd="$(ps -p "$pid" -o args= 2>/dev/null || true)"
    [[ $cmd == *"$torrc"* ]] || taken=1
  done
  (( taken == 1 ))
}

mk_dirs() {
  local user="$1"
  mkdir -p "$BASE" "$META_DIR" "$DATADIR" "$LOGDIR"
  chown -R "$user:$user" "$DATADIR" "$LOGDIR" 2>/dev/null || true
  chmod 755 "$BASE" "$META_DIR"
}

write_files() {
  local cc="$1" port="$2"
  local svc torrc dir log user unit meta
  svc="$(svc_of "$cc")"
  torrc="$(torrc_of "$cc")"
  dir="$DATADIR/$svc"
  log="$LOGDIR/$svc.log"
  user="$(tor_account)"
  unit="/etc/systemd/system/$svc.service"
  meta="$(meta_of "$cc")"

  mk_dirs "$user"
  mkdir -p "$dir"
  touch "$log"
  chown -R "$user:$user" "$dir" "$log" 2>/dev/null || true
  chmod 700 "$dir"

  cat > "$torrc" <<TORRC
# written by $NAME, edit at your own risk
SocksPort 127.0.0.1:${port} IsolateSOCKSAuth
DataDirectory ${dir}
Log notice file ${log}

ClientOnly 1
ExitNodes {${cc}}
StrictNodes 1
AvoidDiskWrites 1
SafeSocks 0
ClientUseIPv6 0
TORRC

  cat > "$unit" <<UNIT
[Unit]
Description=tor egress ${cc} on 127.0.0.1:${port}
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/bin/tor -f ${torrc} --RunAsDaemon 0
Restart=always
RestartSec=5
User=${user}
Group=${user}
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
UNIT

  cat > "$meta" <<META
COUNTRY_CODE="${cc}"
COUNTRY_CODE_UPPER="$(cc_upper "$cc")"
SOCKS_PORT="${port}"
SERVICE_NAME="${svc}"
TORRC_FILE="${torrc}"
DATA_DIR="${dir}"
LOG_FILE="${log}"
CREATED_AT="$(date -Is)"
META
}

via_socks() {
  local port="$1" url="$2" timeout="${3:-20}"
  curl --socks5-hostname "127.0.0.1:${port}" \
    --silent --show-error --location --max-time "$timeout" \
    --connect-timeout 10 -A "$NAME/1.0" "$url"
}

wait_port() {
  local port="$1" max_wait="${2:-$WAIT}" i
  for ((i = 1; i <= max_wait; i++)); do
    nc -z -w 1 127.0.0.1 "$port" >/dev/null 2>&1 && return 0
    sleep 1
  done
  return 1
}

# prints "true|false|<ip>"
tor_state() {
  local port="$1" json is_tor ip
  json="$(via_socks "$port" "https://check.torproject.org/api/ip" 25 2>/dev/null || true)"
  is_tor="$(echo "$json" | jq -r '.IsTor // empty' 2>/dev/null || true)"
  ip="$(echo "$json" | jq -r '.IP // empty' 2>/dev/null || true)"
  echo "${is_tor}|${ip}"
}

# country votes from several places, pipe separated
geo_votes() {
  local port="$1" ip="${2:-}" onionoo v1 v2 v3 v4
  if [[ -n $ip ]]; then
    onionoo="$(curl --silent --location --max-time 20 --connect-timeout 8 \
      "https://onionoo.torproject.org/details?search=${ip}" 2>/dev/null | \
      jq -r '.relays[0].country // empty' 2>/dev/null | tr '[:lower:]' '[:upper:]' || true)"
  fi
  v1="$(via_socks "$port" "https://ipinfo.io/country" 15 2>/dev/null | tr -d '\r\n "' | tr '[:lower:]' '[:upper:]' || true)"
  v2="$(via_socks "$port" "https://ifconfig.co/country-iso" 15 2>/dev/null | tr -d '\r\n "' | tr '[:lower:]' '[:upper:]' || true)"
  v3="$(via_socks "$port" "https://ipapi.co/country/" 15 2>/dev/null | tr -d '\r\n "' | tr '[:lower:]' '[:upper:]' || true)"
  v4="$(via_socks "$port" "https://api.country.is/" 15 2>/dev/null | jq -r '.country // empty' 2>/dev/null | tr -d '\r\n "' | tr '[:lower:]' '[:upper:]' || true)"
  echo "${onionoo:-}|${v1}|${v2}|${v3}|${v4}"
}

# plain web + telegram reachable through the proxy
web_ok() {
  local port="$1" web tg
  web="$(curl --socks5-hostname "127.0.0.1:${port}" --silent --location \
    --output /dev/null --write-out '%{http_code}' --max-time 20 --connect-timeout 8 \
    https://example.com/ 2>/dev/null || true)"
  tg="$(curl --socks5-hostname "127.0.0.1:${port}" --silent \
    --output /dev/null --write-out '%{http_code}' --max-time 20 --connect-timeout 8 \
    https://api.telegram.org/ 2>/dev/null || true)"
  [[ $web == 200 && $tg =~ ^[234][0-9][0-9]$ ]]
}

show_check() {
  local expected="$1" port="$2" is_tor="$3" ip="$4" votes="$5"
  echo "Country expected: ${expected}"
  echo "SOCKS5: 127.0.0.1:${port}"
  echo "Tor check: ${is_tor:-unknown}"
  echo "Exit IP: ${ip:-unknown}"
  echo "Geo votes: ${votes}"
}

check_health() {
  local cc="$1" port="$2" tries="${3:-$TRIES}" wait_secs="${4:-$WAIT}"
  local expected svc attempt state is_tor ip votes hits v
  expected="$(cc_upper "$cc")"
  svc="$(svc_of "$cc")"

  for ((attempt = 1; attempt <= tries; attempt++)); do
    say "health check $svc, try $attempt/$tries"

    if ! systemctl is-active --quiet "$svc"; then
      systemctl restart "$svc" || true
    fi

    if ! wait_port "$port" "$wait_secs"; then
      warn "127.0.0.1:$port not up yet, restarting"
      systemctl restart "$svc" || true
      sleep 5
      continue
    fi

    state="$(tor_state "$port")"
    is_tor="${state%%|*}"
    ip="${state#*|}"
    votes="$(geo_votes "$port" "$ip")"

    hits=0
    IFS='|' read -r -a arr <<< "$votes"
    for v in "${arr[@]}"; do
      [[ $v == "$expected" ]] && hits=$((hits + 1))
    done

    show_check "$expected" "$port" "$is_tor" "$ip" "$votes"

    if [[ $is_tor == true && $hits -ge 1 ]] && web_ok "$port"; then
      ok "node looks good, exit country confirmed: $expected"
      return 0
    fi

    warn "not confirmed, restarting to get a fresh circuit"
    systemctl restart "$svc" || true
    sleep 8
  done

  die "could not confirm $expected after $tries tries" 1
}

# first free port from BASE_PORT up, or the stored one for this cc
pick_port() {
  local cc="$1" port="$BASE_PORT" mf
  mf="$(meta_of "$cc")"
  if [[ -f $mf ]]; then
    # shellcheck disable=SC1090
    source "$mf"
    echo "$SOCKS_PORT"
    return 0
  fi
  while (( port <= 65535 )); do
    if ! ss -ltn 2>/dev/null | grep -qE "[:.]${port}[[:space:]]" \
      && ! grep -Rqs "SOCKS_PORT=\"${port}\"" "$META_DIR" 2>/dev/null; then
      echo "$port"
      return 0
    fi
    port=$((port + 1))
  done
  die "no free tcp port found"
}

cc_label() {
  local up
  up="$(cc_upper "$1")"
  if [[ -r /usr/share/iso-codes/json/iso_3166-1.json ]]; then
    jq -r --arg cc "$up" \
      '.["3166-1"][] | select(.alpha_2 == $cc) | .name' \
      /usr/share/iso-codes/json/iso_3166-1.json 2>/dev/null | head -n1
  else
    echo "$up"
  fi
}

live_countries() {
  local json
  json="$(curl --silent --location --max-time 30 --connect-timeout 10 \
    'https://onionoo.torproject.org/details?type=relay&running=true&flag=Exit&fields=country' \
    2>/dev/null || true)"
  if jq -e '.relays | type == "array"' >/dev/null 2>&1 <<< "$json"; then
    jq -r '.relays[].country // empty' <<< "$json" | \
      tr '[:upper:]' '[:lower:]' | grep -E '^[a-z]{2}$' | sort -u
  else
    # shellcheck disable=SC2086
    printf '%s\n' $FALLBACK
  fi
}

do_add() {
  local cc port svc
  cc="$(cc_lower "$1")"
  ensure_deps
  port="$(port_ok "${2:-$(pick_port "$cc")}")"
  svc="$(svc_of "$cc")"

  say "adding node: country=$cc port=$port"
  systemctl stop "$svc" 2>/dev/null || true

  if port_taken "$port" "$(torrc_of "$cc")"; then
    die "port $port is used by something else, pick another one"
  fi

  write_files "$cc" "$port"

  systemctl daemon-reload
  systemctl enable "$svc"
  systemctl restart "$svc"

  sleep 5
  systemctl status "$svc" --no-pager -l || true

  if check_health "$cc" "$port" "$TRIES" "$WAIT"; then
    echo
    do_json "$cc"
  else
    warn "service is up but the check failed, see '$0 logs $cc' and '$0 test $cc'"
    exit 2
  fi
}

do_test() {
  local cc
  cc="$(cc_lower "$1")"
  load_meta "$cc"
  check_health "$cc" "$SOCKS_PORT" "$TRIES" "$WAIT"
}

do_restart() {
  local cc
  cc="$(cc_lower "$1")"
  load_meta "$cc"
  systemctl restart "$SERVICE_NAME"
  sleep 5
  do_test "$cc"
}

do_upgrade() {
  local mf failed=0
  ensure_deps
  if ! compgen -G "$META_DIR/*.env" >/dev/null; then
    warn "nothing installed, nothing to upgrade"
    return 0
  fi
  say "rewriting torrc files with current settings"
  for mf in "$META_DIR"/*.env; do
    # shellcheck disable=SC1090
    source "$mf"
    write_files "$COUNTRY_CODE" "$SOCKS_PORT"
  done
  systemctl daemon-reload
  for mf in "$META_DIR"/*.env; do
    # shellcheck disable=SC1090
    source "$mf"
    systemctl enable --now "$SERVICE_NAME" >/dev/null 2>&1 || failed=1
    systemctl restart "$SERVICE_NAME" || failed=1
  done
  if (( failed == 0 )); then
    ok "all nodes rewritten and restarted"
  else
    die "some service failed to restart, run '$0 list' and '$0 logs <cc>'"
  fi
}

do_rm() {
  local cc svc torrc mf dir log unit
  cc="$(cc_lower "$1")"
  mf="$(meta_of "$cc")"

  if [[ -f $mf ]]; then
    # shellcheck disable=SC1090
    source "$mf"
    svc="${SERVICE_NAME:-$(svc_of "$cc")}"
    torrc="${TORRC_FILE:-$(torrc_of "$cc")}"
    dir="${DATA_DIR:-$DATADIR/$(svc_of "$cc")}"
    log="${LOG_FILE:-$LOGDIR/$(svc_of "$cc").log}"
  else
    svc="$(svc_of "$cc")"
    torrc="$(torrc_of "$cc")"
    dir="$DATADIR/$svc"
    log="$LOGDIR/$svc.log"
  fi

  unit="/etc/systemd/system/$svc.service"

  say "removing node $cc"
  systemctl stop "$svc" 2>/dev/null || true
  systemctl disable "$svc" 2>/dev/null || true
  rm -f "$unit" "$torrc" "$mf"
  rm -rf "$dir"
  rm -f "$log"
  systemctl daemon-reload
  systemctl reset-failed 2>/dev/null || true
  ok "removed $cc"
}

do_list() {
  local mf active
  mkdir -p "$META_DIR"
  if ! compgen -G "$META_DIR/*.env" >/dev/null; then
    warn "no nodes installed"
    return 0
  fi
  printf "%-8s %-8s %-28s %-10s %-18s\n" "COUNTRY" "PORT" "SERVICE" "ACTIVE" "SOCKS"
  for mf in "$META_DIR"/*.env; do
    # shellcheck disable=SC1090
    source "$mf"
    active="inactive"
    systemctl is-active --quiet "$SERVICE_NAME" && active="active"
    printf "%-8s %-8s %-28s %-10s %-18s\n" \
      "$COUNTRY_CODE_UPPER" "$SOCKS_PORT" "$SERVICE_NAME" "$active" "127.0.0.1:$SOCKS_PORT"
  done
}

do_json() {
  local cc port
  cc="$(cc_lower "$1")"
  load_meta "$cc"
  port="$SOCKS_PORT"
  cat <<JSON

SOCKS5 local:
127.0.0.1:${port}

Xray outbound sample:
{
  "tag": "tor-${cc}",
  "protocol": "socks",
  "settings": {
    "address": "127.0.0.1",
    "port": ${port}
  },
  "targetStrategy": "AsIs"
}
JSON
}

do_logs() {
  local cc
  cc="$(cc_lower "$1")"
  load_meta "$cc"
  echo "===== systemd: $SERVICE_NAME ====="
  journalctl -u "$SERVICE_NAME" --no-pager -n 120 || true
  echo
  echo "===== tor log: $LOG_FILE ====="
  tail -n 120 "$LOG_FILE" 2>/dev/null || true
}

# drop meta files whose service is long gone
do_clean_db() {
  local mf stale=0
  mkdir -p "$META_DIR"
  if ! compgen -G "$META_DIR/*.env" >/dev/null; then
    warn "nothing installed"
    return 0
  fi
  for mf in "$META_DIR"/*.env; do
    # shellcheck disable=SC1090
    source "$mf"
    if [[ ! -f /etc/systemd/system/"$SERVICE_NAME".service ]] \
      && ! systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null; then
      say "dropping stale entry: $COUNTRY_CODE"
      rm -f "$mf"
      stale=$((stale + 1))
    fi
  done
  if (( stale == 0 )); then
    ok "db is clean, nothing stale"
  else
    ok "removed $stale stale entr(y/ies)"
  fi
}

pick_country() {
  local i choice cc name suggested custom
  local -a menu=()
  ensure_deps
  mapfile -t menu < <(live_countries)
  echo "pick a country with a live tor exit right now:"
  i=1
  for cc in "${menu[@]}"; do
    name="$(cc_label "$cc")"
    printf "  %2d) %-32s (%s)\n" "$i" "${name:-$cc}" "$(cc_upper "$cc")"
    i=$((i + 1))
  done
  echo "  ${i}) custom iso code"
  read -r -p "choice: " choice

  if [[ $choice =~ ^[0-9]+$ ]] && (( choice >= 1 && choice < i )); then
    cc="${menu[$((choice - 1))]}"
  elif [[ $choice == "$i" ]]; then
    read -r -p "country code, e.g. es: " cc
    cc="$(cc_lower "$cc")"
  else
    die "bad choice"
  fi

  suggested="$(pick_port "$cc")"
  read -r -p "socks port [$suggested]: " custom
  custom="${custom:-$suggested}"
  do_add "$cc" "$custom"
}

main_menu() {
  local ans cc
  while true; do
    echo
    echo "===== $NAME ====="
    echo "1) add node"
    echo "2) test node"
    echo "3) restart node (new circuit)"
    echo "4) delete node"
    echo "5) list nodes"
    echo "6) xray outbound json"
    echo "7) logs"
    echo "8) upgrade all nodes"
    echo "0) exit"
    read -r -p "select: " ans
    case "$ans" in
      1) pick_country ;;
      2) read -r -p "country code: " cc; do_test "$cc" ;;
      3) read -r -p "country code: " cc; do_restart "$cc" ;;
      4) read -r -p "country code: " cc; do_rm "$cc" ;;
      5) do_list ;;
      6) read -r -p "country code: " cc; do_json "$cc" ;;
      7) read -r -p "country code: " cc; do_logs "$cc" ;;
      8) do_upgrade ;;
      0) exit 0 ;;
      *) warn "bad choice" ;;
    esac
  done
}

main() {
  need_root
  local cmd="${1:-menu}"
  case "$cmd" in
    menu) main_menu ;;
    add|install) [[ $# -ge 2 ]] || { usage; exit 1; }; do_add "$2" "${3:-}" ;;
    test) [[ $# -eq 2 ]] || { usage; exit 1; }; do_test "$2" ;;
    delete|remove) [[ $# -eq 2 ]] || { usage; exit 1; }; do_rm "$2" ;;
    restart) [[ $# -eq 2 ]] || { usage; exit 1; }; do_restart "$2" ;;
    upgrade|fix) [[ $# -eq 1 ]] || { usage; exit 1; }; do_upgrade ;;
    clean-db) [[ $# -eq 1 ]] || { usage; exit 1; }; do_clean_db ;;
    list) do_list ;;
    json) [[ $# -eq 2 ]] || { usage; exit 1; }; do_json "$2" ;;
    logs) [[ $# -eq 2 ]] || { usage; exit 1; }; do_logs "$2" ;;
    help|-h|--help) usage ;;
    *) usage; exit 1 ;;
  esac
}

main "$@"
