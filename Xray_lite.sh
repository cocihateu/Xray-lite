#!/usr/bin/env bash
set -euo pipefail

# ---- UTF-8 bootstrap ----
ensure_utf8_locale() {
  case "${LC_ALL:-${LANG:-}}" in
    *UTF-8*|*utf8*) return 0 ;;
  esac
  if locale -a 2>/dev/null | grep -qi '^C\.UTF-8$'; then
    export LANG=C.UTF-8; export LC_ALL=C.UTF-8; return 0
  fi
  if locale -a 2>/dev/null | grep -qi '^en_US\.utf8$'; then
    export LANG=en_US.UTF-8; export LC_ALL=en_US.UTF-8; return 0
  fi
  if locale -a 2>/dev/null | grep -qi '^zh_CN\.utf8$'; then
    export LANG=zh_CN.UTF-8; export LC_ALL=zh_CN.UTF-8; return 0
  fi
}
ensure_utf8_locale

# ========== Color ==========
C_RST="\033[0m"; C_BAD="\033[1;91m"; C_OK="\033[1;32m"; C_WARN="\033[1;33m"; C_INFO="\033[1;36m"; C_SUB="\033[1;35m"; C_DIM="\033[0;90m"
red(){ printf '\033[1;91m%s\033[0m\n' "$1"; }; green(){ printf '\033[1;32m%s\033[0m\n' "$1"; }; yellow(){ printf '\033[1;33m%s\033[0m\n' "$1"; }; purple(){ printf '\033[1;35m%s\033[0m\n' "$1"; }
clear_buffer(){ while read -r -t 0.08 -n 10000 _d </dev/tty 2>/dev/null; do :; done; }
prompt(){ clear_buffer; printf '\033[1;91m%s\033[0m' "$1" >&2; read -r "$2" </dev/tty; }
pause(){ printf '\n\033[1;91m按回车继续...\033[0m\n' >&2; clear_buffer; read -r _d </dev/tty; }
cls(){ clear; printf '\033[3J\033[2J\033[H'; }
url_encode(){ jq -rn --arg x "$1" '$x|@uri'; }

[ "$EUID" -ne 0 ] && red "请用 root 运行" && exit 1

# 兼容 curl|bash：若 stdin 不是TTY，则尝试切到 /dev/tty
if [ ! -t 0 ]; then
  if [ -r /dev/tty ] && [ -w /dev/tty ]; then
    exec </dev/tty
  else
    red "请在交互终端运行"
    exit 1
  fi
fi

# ========== Smart Menu Render ==========
C_NUM="\033[1;36m"; C_TXT="\033[1;36m"
KW_POOL=("\033[1;32m" "\033[1;35m" "\033[1;33m" "\033[1;91m" "\033[1;92m")
_LAST_KW_IDX=-1

pick_kw_color(){
  local idx=$((RANDOM % ${#KW_POOL[@]}))
  [ "$idx" -eq "$_LAST_KW_IDX" ] && idx=$(((idx+1) % ${#KW_POOL[@]}))
  _LAST_KW_IDX="$idx"
  printf '%b' "${KW_POOL[$idx]}"
}

auto_hl(){
  local s="$1"; local pre kw c left right
  case "$s" in 返回|退出) printf "%b%s%b" "$C_BAD" "$s" "$C_RST"; return ;; esac
  if [[ "$s" == *卸载* ]]; then
    left="${s%%卸载*}"; right="${s#*卸载}"
    printf "%b%s%b%b卸载%b%b%s%b" "$C_TXT" "$left" "$C_RST" "$C_BAD" "$C_RST" "$C_TXT" "$right" "$C_RST"
    return
  fi
  for pre in 管理 安装 查看 修改 重启 设置 创建 实时 配置 启用 关闭 删除 添加 定时 彻底 更新; do
    if [[ "$s" == "$pre"* ]]; then
      kw="${s#$pre}"
      if [ -z "$kw" ]; then printf "%b%s%b" "$C_TXT" "$s" "$C_RST"; else
        c="$(pick_kw_color)"; printf "%b%s%b%b%s%b" "$C_TXT" "$pre" "$C_RST" "$c" "$kw" "$C_RST"; fi
      return
    fi
  done
  printf "%b%s%b" "$C_TXT" "$s" "$C_RST"
}

strip_ansi(){ sed -r 's/\x1B\[[0-9;]*[A-Za-z]//g'; }
vlen(){ printf '%s' "$1" | strip_ansi | awk '{print length}'; }
term_cols(){ local c; c="$(tput cols 2>/dev/null || stty size 2>/dev/null | awk '{print $2}' || echo 80)"; [ -z "$c" ] && c=80; echo "$c"; }

menu_row2_auto(){
  local lnum="$1" ltxt="$2" rnum="${3:-}" rtxt="${4:-}"
  local left right right_col=20
  left="$(printf "%b%2s.%b %s" "$C_NUM" "$lnum" "$C_RST" "$(auto_hl "$ltxt")")"
  if [ -z "$rnum" ] || [ -z "$rtxt" ]; then printf "%s\n" "$left"; return; fi
  right="$(printf "%b%2s.%b %s" "$C_NUM" "$rnum" "$C_RST" "$(auto_hl "$rtxt")")"
  printf "%s\033[%sG%s\n" "$left" "$right_col" "$right"
}

menu_item_auto(){
  local num="$1" txt="$2"
  printf "%b%2s.%b %s\n" "$C_NUM" "$num" "$C_RST" "$(auto_hl "$txt")"
}

# ========== Paths ==========
WORK="/etc/xray"
XRAY_BIN="${WORK}/xray"
XRAY_CONF="${WORK}/config.json"

TLS_BASE="/etc/lite/tls"
TLS_DIR_HY2="${TLS_BASE}/hy2"

CF_API_CONF="${WORK}/cloudflare_api.conf"
CF_API_BOOTSTRAP_DONE="${WORK}/cloudflare_api_bootstrap.done"

ARGO_DOMAIN="${WORK}/domain_argo.txt"
ARGO_YML="${WORK}/tunnel_argo.yml"
ARGO_JSON="${WORK}/tunnel_argo.json"
ARGO_TOKEN_FILE="${WORK}/tunnel_argo.token"
ARGO_TUNNEL_ID_FILE="${WORK}/tunnel_argo.id"

# CF加速模式: argo | origin
# origin 模式使用固定回源端口
CF_MODE_CONF="${WORK}/cf_mode.conf"
CF_MODE="argo"
ORIGIN_VLESS_WS_PORT=62481
ORIGIN_VLESS_XHTTP_PORT=62482
ORIGIN_SS_WS_PORT=62483

OUTBOUND_CONF="${WORK}/outbound_policy.conf"
IPCACHE="${WORK}/ip_cache.conf"

# HY2 多实例列表
HY2_LIST="${WORK}/hy2_list.json"
# Reality 多实例列表
REALITY_LIST="${WORK}/reality_list.json"

SWAP_LOG="/tmp/swap.log"

# 监控
MONITOR_LOG="${WORK}/monitor_argo.log"
MONITOR_DOWN_COUNT="${WORK}/monitor_argo_down.count"

UUID_FALLBACK="$(cat /proc/sys/kernel/random/uuid)"
CFIP=${CFIP:-'172.67.146.150'}
SS_FIXED_IP="172.64.147.74"

# XHTTP random padding header/key (<=6 alnum)
XHTTP_PAD="$(tr -dc 'a-zA-Z0-9' </dev/urandom 2>/dev/null | head -c 6 || true)"

XHTTP_MODE="auto"
XHTTP_EXTRA_JSON="{\"xPaddingObfsMode\":true,\"xPaddingMethod\":\"tokenish\",\"xPaddingPlacement\":\"queryInHeader\",\"xPaddingHeader\":\"${XHTTP_PAD}\",\"xPaddingKey\":\"_${XHTTP_PAD}\"}"

HY2_SELF_SNI_DEFAULT="www.amd.com"

GHFAST_PREFIX="https://ghfast.top/"
GH_SPEED_THRESHOLD_MBPS=20
GH_SPEED_THRESHOLD_BPS=2500000
GH_USE_FAST_MIRROR=0

SCRIPT_URL_DEFAULT="https://raw.githubusercontent.com/cocihateu/Xray-lite/refs/heads/main/Xray_lite.sh"
SCRIPT_URL="${SCRIPT_URL:-$SCRIPT_URL_DEFAULT}"

YOUTUBE_MODE=1
V6_SITES=""

IP_CHECKED=0; IP_CACHE_MTIME=0; WAN4=""; WAN6=""; COUNTRY4=""; COUNTRY6=""; ISP4=""; ISP6=""; EMOJI4=""; EMOJI6=""; BASE_REGION="Node"; BASE_FULL="Node"
CPU_LAST_TOTAL=0; CPU_LAST_IDLE=0
CF_API_TOKEN=""; CF_API_ACCOUNT_ID=""

# ========== Service ==========
is_alpine(){ [ -f /etc/alpine-release ]; }
service_exists(){ local s="$1"; if is_alpine; then [ -f "/etc/init.d/${s}" ]; else [ -f "/etc/systemd/system/${s}.service" ] || systemctl list-unit-files 2>/dev/null | grep -q "^${s}\.service"; fi; }
svc(){ local act="$1" s="$2"; if is_alpine; then case "$act" in start|stop|restart) rc-service "$s" "$act" >/dev/null 2>&1 || true ;; enable) rc-update add "$s" default >/dev/null 2>&1 || true ;; disable) rc-update del "$s" default >/dev/null 2>&1 || true ;; esac; else case "$act" in enable) systemctl enable "$s" >/dev/null 2>&1 || true; systemctl daemon-reload >/dev/null 2>&1 || true ;; disable) systemctl disable "$s" >/dev/null 2>&1 || true; systemctl daemon-reload >/dev/null 2>&1 || true ;; *) systemctl "$act" "$s" >/dev/null 2>&1 || true ;; esac; fi; }
is_running(){ if is_alpine; then rc-service "$1" status 2>/dev/null | grep -q started; else [ "$(systemctl is-active "$1" 2>/dev/null)" = "active" ]; fi; }

# ========== Package ==========
need_cmd(){ command -v "$1" >/dev/null 2>&1; }
pkg_install(){
  [ "$#" -eq 0 ] && return 0
  local mgr=""
  if command -v apt-get >/dev/null 2>&1; then mgr="apt"; elif command -v dnf >/dev/null 2>&1; then mgr="dnf"; elif command -v yum >/dev/null 2>&1; then mgr="yum"; elif command -v apk >/dev/null 2>&1; then mgr="apk"; else red "未找到可用包管理器"; return 1; fi
  local pkgs=() p mapped
  for p in "$@"; do
    mapped="$p"
    case "$mgr:$p" in dnf:iproute2|yum:iproute2) mapped="iproute" ;; apk:coreutils) mapped="coreutils" ;; apt:iproute2|apk:iproute2) mapped="iproute2" ;; esac
    pkgs+=("$mapped")
  done
  case "$mgr" in
    apt) apt-get update -y >/dev/null 2>&1 || true; DEBIAN_FRONTEND=noninteractive apt-get install -y "${pkgs[@]}" >/dev/null 2>&1 || true ;;
    dnf) dnf install -y "${pkgs[@]}" >/dev/null 2>&1 || true ;;
    yum) yum install -y "${pkgs[@]}" >/dev/null 2>&1 || true ;;
    apk) apk add --no-cache "${pkgs[@]}" >/dev/null 2>&1 || true ;;
  esac
}
ensure_deps(){
  need_cmd jq || pkg_install jq
  need_cmd wget || pkg_install wget
  need_cmd ip || pkg_install iproute2
  need_cmd base64 || pkg_install coreutils
  need_cmd tar || pkg_install tar
  need_cmd unzip || pkg_install unzip
  need_cmd openssl || pkg_install openssl
  need_cmd ss || pkg_install iproute2
  need_cmd curl || pkg_install curl
  [ -f /etc/alpine-release ] && pkg_install ca-certificates || true
  for c in jq wget ip ss base64 tar unzip openssl curl; do
    command -v "$c" >/dev/null 2>&1 || { red "依赖缺失: $c"; return 1; }
  done
  return 0
}

# ========== Helpers ==========
rand_alnum(){
  local n="${1:-6}"
  tr -dc 'a-zA-Z0-9' </dev/urandom 2>/dev/null | head -c "$n" || true
}
rand_hex(){
  local n="${1:-8}"
  tr -dc 'a-f0-9' </dev/urandom 2>/dev/null | head -c "$n" || true
}

detect_xray_arch(){
  case "$(uname -m)" in
    x86_64|amd64) echo "64" ;; aarch64|arm64) echo "arm64-v8a" ;; i?86) echo "32" ;; armv7l|armv7|armhf) echo "arm32-v7a" ;; armv6l|armv6) echo "arm32-v6" ;; s390x) echo "s390x" ;; riscv64) echo "riscv64" ;; *) echo "" ;;
  esac
}
detect_cloudflared_arch(){
  case "$(uname -m)" in
    x86_64|amd64) echo "amd64" ;; aarch64|arm64) echo "arm64" ;; i?86) echo "386" ;; armv7l|armv7|armhf) echo "arm" ;; *) echo "" ;;
  esac
}
normalize_path(){ [ -z "${1:-}" ] && echo "/" || { case "$1" in /*) echo "$1" ;; *) echo "/$1" ;; esac; }; }
gen_uuid(){ cat /proc/sys/kernel/random/uuid; }

xray_x25519_keys(){
  [ -x "$XRAY_BIN" ] || return 1
  local out priv pub

  out="$("$XRAY_BIN" x25519 2>&1 || true)"

  priv="$(printf '%s\n' "$out" \
    | sed -nE 's/^[[:space:]]*Private[[:space:]]*Key[[:space:]]*:[[:space:]]*([^[:space:]]+).*/\1/Ip' \
    | head -n1)"

  pub="$(printf '%s\n' "$out" \
    | sed -nE 's/^.*Public[[:space:]]*Key\)?[[:space:]]*:[[:space:]]*([^[:space:]]+).*/\1/Ip' \
    | head -n1)"

  [ -n "$priv" ] && [ -n "$pub" ] || return 1
  echo "${priv}|${pub}"
}

is_github_url(){
  case "$1" in https://github.com/*|https://raw.githubusercontent.com/*) return 0 ;; *) return 1 ;; esac
}
ghfast_url(){ local u="$1"; echo "${GHFAST_PREFIX}${u}"; }

port_exists_in_conf(){
  local p="$1"
  jq --argjson p "$p" '[.inbounds[]? | select(.port==$p)] | length' "$XRAY_CONF" 2>/dev/null | grep -qv '^0$'
}
random_free_port(){
  local p
  while true; do
    p=$(( ((RANDOM << 15) | RANDOM) % 65535 + 1 ))
    if ss -tuln 2>/dev/null | grep -q ":${p} "; then
      continue
    fi
    if [ -f "$XRAY_CONF" ] && port_exists_in_conf "$p"; then
      continue
    fi
    echo "$p"
    return
  done
}

smart_download(){
  local out="$1" url="$2" min="$3"
  local t=0 u="" is_gh=0 elapsed sz speed
  is_github_url "$url" && is_gh=1 || is_gh=0
  while [ "$t" -lt 3 ]; do
    rm -f "$out"
    if [ "$is_gh" -eq 1 ] && [ "${GH_USE_FAST_MIRROR:-0}" -eq 1 ]; then
      u="$(ghfast_url "$url")"
    else
      u="$url"
    fi
    local ts_start ts_end
    ts_start="$(date +%s)"
    if command -v curl >/dev/null 2>&1; then curl -L --connect-timeout 10 --max-time 180 -o "$out" "$u" >/dev/null 2>&1 || true; fi
    if [ ! -s "$out" ] && command -v wget >/dev/null 2>&1; then
      if wget --help 2>&1 | grep -q -- '--show-progress'; then wget -q --show-progress --timeout=40 --tries=1 -O "$out" "$u" || true; else wget -q -T 40 -O "$out" "$u" || true; fi
    fi
    ts_end="$(date +%s)"; elapsed=$((ts_end - ts_start)); [ "$elapsed" -le 0 ] && elapsed=1
    if [ -f "$out" ]; then
      sz="$(wc -c < "$out" 2>/dev/null || echo 0)"; speed=$((sz / elapsed))
      if [ "${sz:-0}" -ge "$min" ]; then
        if [ "$is_gh" -eq 1 ] && [ "${GH_USE_FAST_MIRROR:-0}" -eq 0 ] && [ "$u" = "$url" ]; then
          if [ "$speed" -lt "${GH_SPEED_THRESHOLD_BPS:-2500000}" ]; then
            yellow "GitHub主站速度低于${GH_SPEED_THRESHOLD_MBPS}Mbps，切换并锁定 ghfast 备用源"
            GH_USE_FAST_MIRROR=1; rm -f "$out"; t=$((t+1)); sleep 1; continue
          fi
        fi
        return 0
      fi
    fi
    if [ "$is_gh" -eq 1 ] && [ "${GH_USE_FAST_MIRROR:-0}" -eq 0 ] && [ "$u" = "$url" ]; then
      yellow "GitHub主站下载失败，切换并锁定 ghfast 备用源"
      GH_USE_FAST_MIRROR=1
    fi
    rm -f "$out"; t=$((t+1)); sleep 2
  done
  return 1
}
update_xray(){
  if ! jq "$@" "$XRAY_CONF" > "${XRAY_CONF}.tmp"; then rm -f "${XRAY_CONF}.tmp"; red "配置更新失败"; return 1; fi
  mv "${XRAY_CONF}.tmp" "$XRAY_CONF"
}
ensure_acme(){
  need_cmd openssl || pkg_install openssl
  command -v openssl >/dev/null 2>&1 || { red "缺少 openssl，无法安装 acme.sh"; return 1; }
  [ -x "$HOME/.acme.sh/acme.sh" ] && return 0

  if ! command -v crontab >/dev/null 2>&1; then
    if command -v apt-get >/dev/null 2>&1; then
      pkg_install cron; svc enable cron; svc start cron
    elif command -v apk >/dev/null 2>&1; then
      pkg_install dcron
      rc-service dcron start >/dev/null 2>&1 || true
      rc-update add dcron default >/dev/null 2>&1 || true
    else
      pkg_install cronie; svc enable crond; svc start crond
    fi
  fi

  yellow "安装 acme.sh..."
  curl -s https://get.acme.sh | sh >/tmp/acme_install.log 2>&1 || true
  [ -x "$HOME/.acme.sh/acme.sh" ] || {
    red "acme.sh 安装失败"
    tail -n 80 /tmp/acme_install.log 2>/dev/null || true
    return 1
  }
}

detect_ssh_ports(){
  {
    echo 22
    if [ -n "${SSH_CONNECTION:-}" ]; then
      echo "$SSH_CONNECTION" | awk '{print $4}'
    fi
    if [ -f /etc/ssh/sshd_config ]; then
      awk '/^[[:space:]]*Port[[:space:]]+[0-9]+([[:space:]]|$)/{print $2}' /etc/ssh/sshd_config
    fi
  } | grep -E '^[0-9]+$' | awk '$1>=1 && $1<=65535' | sort -n | uniq
}

protect_ssh_ufw(){
  local sp
  while read -r sp; do
    [ -n "$sp" ] || continue
    ufw allow "${sp}/tcp" >/dev/null 2>&1 || true
  done < <(detect_ssh_ports)
}

protect_ssh_firewalld(){
  local sp
  while read -r sp; do
    [ -n "$sp" ] || continue
    firewall-cmd --add-port="${sp}/tcp" --permanent >/dev/null 2>&1 || true
  done < <(detect_ssh_ports)
}

nft_input_base_chains(){
  command -v nft >/dev/null 2>&1 || return 1
  command -v jq  >/dev/null 2>&1 || return 1

  nft -j list ruleset 2>/dev/null | jq -r '
    .nftables
    | map(select(.table or .chain))
    | . as $all
    | [ .[] | .table? ] as $tables
    | [ .[] | .chain?
        | select(.hook=="input")
        | select((.type // "filter") == "filter")
        | {family, table, name}
      ] as $chains
    | $chains[]
    | "\(.family)|\(.table)|\(.name)"
  ' 2>/dev/null
}

open_port_nft(){
  local p="$1" proto="${2:-tcp}"
  local fam tbl chn ok=0

  while IFS='|' read -r fam tbl chn; do
    [ -n "$fam" ] && [ -n "$tbl" ] && [ -n "$chn" ] || continue
    if nft list chain "$fam" "$tbl" "$chn" 2>/dev/null \
      | grep -Eq "\\b${proto}\\s+dport\\s+${p}\\b.*\\baccept\\b"; then
      ok=1
      continue
    fi
    nft add rule "$fam" "$tbl" "$chn" "$proto" dport "$p" accept >/dev/null 2>&1 && ok=1 || true
  done < <(nft_input_base_chains)

  [ "$ok" -eq 1 ]
}

open_port(){
  local p="$1" proto="${2:-tcp}"

  if command -v ufw >/dev/null 2>&1; then
    if ufw status 2>/dev/null | grep -qi '^Status: active'; then
      ufw allow "${p}/${proto}" >/dev/null 2>&1 && {
        green "端口已放行(ufw): ${p}/${proto}"
        return 0
      }
    fi
  fi

  if command -v firewall-cmd >/dev/null 2>&1; then
    if firewall-cmd --state 2>/dev/null | grep -qi '^running$'; then
      firewall-cmd --add-port="${p}/${proto}" --permanent >/dev/null 2>&1 || true
      firewall-cmd --reload >/dev/null 2>&1 || true
      if firewall-cmd --list-ports 2>/dev/null | grep -Eq "(^|[[:space:]])${p}/${proto}([[:space:]]|$)"; then
        green "端口已放行(firewalld): ${p}/${proto}"
        return 0
      fi
    fi
  fi

  if command -v nft >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
    if open_port_nft "$p" "$proto"; then
      green "端口已放行(nftables): ${p}/${proto}"
      return 0
    fi
  fi

  if command -v iptables >/dev/null 2>&1; then
    local ok4=1 ok6=1
    iptables -C INPUT -p "$proto" --dport "$p" -j ACCEPT >/dev/null 2>&1 || \
      iptables -I INPUT -p "$proto" --dport "$p" -j ACCEPT >/dev/null 2>&1 || ok4=0

    if command -v ip6tables >/dev/null 2>&1; then
      ip6tables -C INPUT -p "$proto" --dport "$p" -j ACCEPT >/dev/null 2>&1 || \
        ip6tables -I INPUT -p "$proto" --dport "$p" -j ACCEPT >/dev/null 2>&1 || ok6=0
    fi

    if [ "$ok4" -eq 1 ] || [ "$ok6" -eq 1 ]; then
      green "端口已放行(iptables): ${p}/${proto}"
      return 0
    fi
  fi

  yellow "未检测到活动防火墙或添加失败，请手动放行: ${p}/${proto}"
  return 1
}

# ========== State ==========
cf_mode_display(){
  local has_domain=0 has_argo=0 has_origin=0
  [ -s "$ARGO_DOMAIN" ] && has_domain=1

  if [ -f "$XRAY_CONF" ]; then
    jq -e '.inbounds[]? | select(.port==8081 or .port==8082 or .port==8083)' "$XRAY_CONF" >/dev/null 2>&1 && has_argo=1 || true
    jq -e --argjson p1 "$ORIGIN_VLESS_WS_PORT" --argjson p2 "$ORIGIN_VLESS_XHTTP_PORT" --argjson p3 "$ORIGIN_SS_WS_PORT" \
      '.inbounds[]? | select(.port==$p1 or .port==$p2 or .port==$p3)' "$XRAY_CONF" >/dev/null 2>&1 && has_origin=1 || true
  fi

  if [ "$has_domain" -eq 0 ] && [ "$has_argo" -eq 0 ] && [ "$has_origin" -eq 0 ]; then
    echo "未配置"
    return
  fi

  [ "$CF_MODE" = "origin" ] && echo "端口回源" || echo "Argo隧道"
}

load_cf_mode(){
  if [ -f "$CF_MODE_CONF" ]; then
    CF_MODE="$(awk -F= '/^CF_MODE=/{print $2}' "$CF_MODE_CONF" 2>/dev/null || echo "argo")"
  fi
  case "$CF_MODE" in
    argo|origin) ;;
    *) CF_MODE="argo" ;;
  esac
}
save_cf_mode(){
  mkdir -p "$WORK"
  cat > "$CF_MODE_CONF" <<EOF
CF_MODE=${CF_MODE}
EOF
}

load_state(){
  if [ -f "$OUTBOUND_CONF" ]; then
    YOUTUBE_MODE="$(awk -F= '/^YOUTUBE_MODE=/{print $2}' "$OUTBOUND_CONF" 2>/dev/null)"
    [[ "$YOUTUBE_MODE" =~ ^[12]$ ]] || YOUTUBE_MODE=1
    V6_SITES="$(awk -F= '/^V6_SITES=/{print $2}' "$OUTBOUND_CONF" 2>/dev/null)"
  fi
  load_cf_mode
  load_cf_api >/dev/null 2>&1 || true
}
save_outbound(){
  mkdir -p "$WORK"
  cat > "$OUTBOUND_CONF" <<EOF
YOUTUBE_MODE=${YOUTUBE_MODE}
V6_SITES=${V6_SITES}
EOF
}

# ========== Cloudflare API ==========
load_cf_api(){
  [ -f "$CF_API_CONF" ] || return 1
  . "$CF_API_CONF" 2>/dev/null || return 1
  return 0
}
save_cf_api(){
  mkdir -p "$WORK"
  cat > "$CF_API_CONF" <<EOF
CF_API_TOKEN=$(printf '%q' "${CF_API_TOKEN:-}")
CF_API_ACCOUNT_ID=$(printf '%q' "${CF_API_ACCOUNT_ID:-}")
EOF
  chmod 600 "$CF_API_CONF" 2>/dev/null || true
}
cf_show_token_guide(){
  cat >&2 <<'EOF'

================ Cloudflare Token 创建说明 ================
1) 登录 Cloudflare Dashboard
2) 右上角头像 -> My Profile -> API Tokens -> Create Token
3) 选择 Create Custom Token
4) 推荐名称：xray-lite-auto
5) 建议权限：
   - Account > Cloudflare Tunnel > Edit
   - Account > Account Rulesets > Edit
   - Account > Account Filter Lists > Edit
   - Zone > DNS > Edit
   - Zone > Zone > Read
   - Zone > Origin Rules > Edit
   - Zone > Cache Rules > Edit
6) Account Resources：
   - Include -> 你的 Account（或 All accounts）
7) Zone Resources：
   - Include -> 你的域名所在 Zone（或 All zones）
8) 创建后复制 Token，粘贴到脚本即可

用途：
- Argo 自动创建 Tunnel + 下发远程 ingress + 自动建 DNS
- 端口回源自动配置 Origin Rules
- XHTTP 自动配置绕过缓存 Cache Rules
- HY2 使用 CF DNS API 自动签发证书
==========================================================

EOF
}
cf_bootstrap_once(){
  local feature="${1:-功能}" yn tok
  load_cf_api >/dev/null 2>&1 || true
  [ -f "$CF_API_BOOTSTRAP_DONE" ] && return 0
  if [ -n "${CF_API_TOKEN:-}" ]; then
    touch "$CF_API_BOOTSTRAP_DONE"
    return 0
  fi
  cls
  echo -e "${C_WARN}=========== Cloudflare 自动配置 ===========${C_RST}"
  echo "检测到首次安装 ${feature}"
  echo "是否保存一个全局 Cloudflare API Token 供后续自动化复用："
  echo " - Argo 自动建 Tunnel"
  echo " - CF 端口回源自动建 Origin Rules"
  echo " - XHTTP 自动建绕过缓存 Cache Rules"
  echo " - HY2 复用 Token 自动签证书"
  echo "-------------------------------------"
  prompt "是否现在配置全局 Cloudflare API Token? (y/N): " yn
  case "${yn:-N}" in
    y|Y|yes|YES)
      cf_show_token_guide
      prompt "请输入 Cloudflare API Token: " tok
      if [ -n "$tok" ]; then
        CF_API_TOKEN="$tok"
        save_cf_api
        green "Cloudflare API Token 已保存"
      else
        yellow "未输入 Token，已跳过"
      fi
      ;;
    *)
      yellow "已跳过 Cloudflare 自动配置引导"
      ;;
  esac
  touch "$CF_API_BOOTSTRAP_DONE"
}
cf_require_token(){
  local tok
  load_cf_api >/dev/null 2>&1 || true
  [ -n "${CF_API_TOKEN:-}" ] && return 0
  yellow "当前未配置全局 Cloudflare API Token"
  cf_show_token_guide
  prompt "请输入 Cloudflare API Token(留空取消): " tok
  [ -n "$tok" ] || { red "未输入 Token"; return 1; }
  CF_API_TOKEN="$tok"
  save_cf_api
  green "Cloudflare API Token 已保存"
}
cf_ref_safe(){
  echo "$1" | tr '.:/-@' '_' | tr -cd 'a-zA-Z0-9_' | cut -c1-40
}
cf_api_call(){
  local method="$1" endpoint="$2" data="${3:-}" resp errf="/tmp/cf_api_err.log"
  load_cf_api >/dev/null 2>&1 || true
  [ -n "${CF_API_TOKEN:-}" ] || { red "未配置 Cloudflare API Token"; return 1; }

  if [ -n "$data" ]; then
    resp="$(curl -fsS -X "$method" "https://api.cloudflare.com/client/v4${endpoint}" \
      -H "Authorization: Bearer ${CF_API_TOKEN}" \
      -H "Content-Type: application/json" \
      --data "$data" 2>"$errf" || true)"
  else
    resp="$(curl -fsS -X "$method" "https://api.cloudflare.com/client/v4${endpoint}" \
      -H "Authorization: Bearer ${CF_API_TOKEN}" \
      -H "Content-Type: application/json" 2>"$errf" || true)"
  fi

  [ -n "$resp" ] || {
    red "Cloudflare API 请求失败: ${endpoint}"
    tail -n 20 "$errf" 2>/dev/null >&2 || true
    return 1
  }

  if ! echo "$resp" | jq -e '.success == true' >/dev/null 2>&1; then
    red "Cloudflare API 返回失败: ${endpoint}"
    echo "$resp" | jq -r '.errors[]? | "- \(.message // .code // "unknown error")"' 2>/dev/null >&2 || echo "$resp" >&2
    return 1
  fi

  printf '%s\n' "$resp"
}
cf_get_zone_meta_by_domain(){
  local domain cand resp len zid zname aid
  domain="$(normalize_domain_item "$1")"
  [ -n "$domain" ] || return 1
  cand="$domain"
  while [ -n "$cand" ]; do
    resp="$(cf_api_call GET "/zones?name=$(url_encode "$cand")&status=active&per_page=1" "" 2>/dev/null || true)"
    if [ -n "$resp" ]; then
      len="$(echo "$resp" | jq -r '.result | length' 2>/dev/null || echo 0)"
      if [ "${len:-0}" -gt 0 ]; then
        zid="$(echo "$resp" | jq -r '.result[0].id // empty')"
        zname="$(echo "$resp" | jq -r '.result[0].name // empty')"
        aid="$(echo "$resp" | jq -r '.result[0].account.id // empty')"
        [ -n "$aid" ] && CF_API_ACCOUNT_ID="$aid" && save_cf_api || true
        echo "${zid}|${zname}|${aid}"
        return 0
      fi
    fi
    [[ "$cand" == *.* ]] || break
    cand="${cand#*.}"
  done
  return 1
}
cf_resolve_zone_and_account_interactive(){
  local domain="$1" meta zid aid zname
  meta="$(cf_get_zone_meta_by_domain "$domain" || true)"
  if [ -n "$meta" ]; then
    echo "$meta"
    return 0
  fi
  yellow "未能根据域名自动识别 Zone / Account，请手动输入"
  prompt "Zone ID: " zid
  [ -n "$zid" ] || { red "Zone ID 不能为空"; return 1; }
  prompt "Account ID: " aid
  [ -n "$aid" ] || { red "Account ID 不能为空"; return 1; }
  zname="$(normalize_domain_item "$domain")"
  CF_API_ACCOUNT_ID="$aid"; save_cf_api
  echo "${zid}|${zname}|${aid}"
}
cf_upsert_dns_record_cname(){
  local zone_id="$1" name="$2" target="$3"
  local resp recid payload
  name="$(normalize_domain_item "$name")"
  payload="$(jq -nc --arg name "$name" --arg content "$target" '{"type":"CNAME","name":$name,"content":$content,"proxied":true}')"
  resp="$(cf_api_call GET "/zones/${zone_id}/dns_records?name=$(url_encode "$name")&per_page=100" "")" || return 1
  recid="$(echo "$resp" | jq -r '.result[0].id // empty')"
  if [ -n "$recid" ]; then
    cf_api_call PUT "/zones/${zone_id}/dns_records/${recid}" "$payload" >/dev/null || return 1
  else
    cf_api_call POST "/zones/${zone_id}/dns_records" "$payload" >/dev/null || return 1
  fi
  green "Cloudflare DNS 已更新: ${name} -> ${target}"
}
cf_get_or_create_ruleset(){
  local zone_id="$1" phase="$2" name="$3" desc="$4"
  local resp rid payload
  resp="$(cf_api_call GET "/zones/${zone_id}/rulesets?phase=$(url_encode "$phase")" "" || true)"
  rid="$(echo "$resp" | jq -r '.result[]? | select(.phase=="'"${phase}"'") | .id' 2>/dev/null | head -n1 || true)"
  if [ -n "$rid" ]; then
    echo "$rid"
    return 0
  fi
  payload="$(jq -nc --arg name "$name" --arg desc "$desc" --arg phase "$phase" '{"name":$name,"description":$desc,"kind":"zone","phase":$phase,"rules":[]}')"
  resp="$(cf_api_call POST "/zones/${zone_id}/rulesets" "$payload")" || return 1
  echo "$resp" | jq -r '.result.id'
}
cf_upsert_ruleset_rule(){
  local zone_id="$1" rid="$2" ref="$3" action="$4" expr="$5" desc="$6" action_params="$7"
  local resp curr newrule newrules payload
  resp="$(cf_api_call GET "/zones/${zone_id}/rulesets/${rid}" "")" || return 1
  curr="$(echo "$resp" | jq '.result.rules // []')"
  newrule="$(jq -nc \
    --arg ref "$ref" \
    --arg action "$action" \
    --arg expr "$expr" \
    --arg desc "$desc" \
    --argjson ap "$action_params" \
    '{"ref":$ref,"description":$desc,"expression":$expr,"action":$action,"action_parameters":$ap,"enabled":true}')"
  newrules="$(jq -nc --argjson curr "$curr" --argjson nr "$newrule" '($curr | map(select(.ref != $nr.ref))) + [$nr]')"
  payload="$(jq -nc --argjson rules "$newrules" '{"rules":$rules}')"
  cf_api_call PUT "/zones/${zone_id}/rulesets/${rid}" "$payload" >/dev/null || return 1
}
cf_apply_origin_rules_for_domain(){
  local domain="$1" meta zone_id zone_name account_id rid safe expr ap
  load_cf_api >/dev/null 2>&1 || true
  [ -n "${CF_API_TOKEN:-}" ] || { yellow "未配置全局 Cloudflare API Token，已跳过 Origin Rules 自动配置"; return 1; }

  meta="$(cf_resolve_zone_and_account_interactive "$domain")" || return 1
  IFS='|' read -r zone_id zone_name account_id <<< "$meta"
  rid="$(cf_get_or_create_ruleset "$zone_id" "http_request_origin" "Origin Rules ruleset" "Zone-level ruleset that will execute origin rules.")" || return 1
  safe="$(cf_ref_safe "$domain")"

  expr="(http.host eq \"${domain}\" and starts_with(http.request.uri.path, \"/argo\"))"
  ap='{"origin":{"port":62481}}'
  cf_upsert_ruleset_rule "$zone_id" "$rid" "xray_origin_ws_${safe}" "route" "$expr" "Xray CF-Origin WS /argo -> 62481" "$ap" || return 1

  expr="(http.host eq \"${domain}\" and starts_with(http.request.uri.path, \"/xgo\"))"
  ap='{"origin":{"port":62482}}'
  cf_upsert_ruleset_rule "$zone_id" "$rid" "xray_origin_xhttp_${safe}" "route" "$expr" "Xray CF-Origin XHTTP /xgo -> 62482" "$ap" || return 1

  expr="(http.host eq \"${domain}\" and starts_with(http.request.uri.path, \"/ssgo\"))"
  ap='{"origin":{"port":62483}}'
  cf_upsert_ruleset_rule "$zone_id" "$rid" "xray_origin_ss_${safe}" "route" "$expr" "Xray CF-Origin SS /ssgo -> 62483" "$ap" || return 1

  green "Cloudflare Origin Rules 已自动配置: ${domain}"
}
cf_apply_xhttp_cache_bypass_for_domain(){
  local domain="$1" meta zone_id zone_name account_id rid safe expr ap
  load_cf_api >/dev/null 2>&1 || true
  [ -n "${CF_API_TOKEN:-}" ] || { yellow "未配置全局 Cloudflare API Token，已跳过 Cache Rules 自动配置"; return 1; }

  meta="$(cf_resolve_zone_and_account_interactive "$domain")" || return 1
  IFS='|' read -r zone_id zone_name account_id <<< "$meta"
  rid="$(cf_get_or_create_ruleset "$zone_id" "http_request_cache_settings" "Cache Rules ruleset" "Zone-level ruleset that will execute cache rules.")" || return 1
  safe="$(cf_ref_safe "$domain")"

  expr="(http.host eq \"${domain}\" and starts_with(http.request.uri.path, \"/xgo\"))"
  ap='{"cache":false}'
  cf_upsert_ruleset_rule "$zone_id" "$rid" "xray_xhttp_bypass_cache_${safe}" "set_cache_settings" "$expr" "Bypass cache for Xray XHTTP /xgo" "$ap" || return 1

  green "Cloudflare Cache Rules 已自动配置: XHTTP /xgo 绕过缓存"
}
cf_create_argo_tunnel_remote(){
  local domain="$1" meta zone_id zone_name account_id tunnel_name payload resp tunnel_id tunnel_token
  cf_require_token || return 1

  meta="$(cf_resolve_zone_and_account_interactive "$domain")" || return 1
  IFS='|' read -r zone_id zone_name account_id <<< "$meta"
  [ -n "$account_id" ] || account_id="${CF_API_ACCOUNT_ID:-}"
  [ -n "$account_id" ] || { red "无法确定 Cloudflare Account ID"; return 1; }

  tunnel_name="xray-$(hostname 2>/dev/null | tr -dc 'a-zA-Z0-9' | head -c 12)-$(rand_alnum 6)"
  payload="$(jq -nc --arg name "$tunnel_name" '{"name":$name,"config_src":"cloudflare"}')"
  resp="$(cf_api_call POST "/accounts/${account_id}/cfd_tunnel" "$payload")" || return 1

  tunnel_id="$(echo "$resp" | jq -r '.result.id // empty')"
  tunnel_token="$(echo "$resp" | jq -r '.result.token // empty')"
  [ -n "$tunnel_id" ] && [ -n "$tunnel_token" ] || { red "Tunnel 创建成功但未取到 id/token"; return 1; }

  payload="$(jq -nc --arg domain "$domain" '{
    "config":{
      "ingress":[
        {"hostname":$domain,"path":"/argo","service":"http://localhost:8081","originRequest":{"noTLSVerify":true}},
        {"hostname":$domain,"path":"/xgo","service":"http://localhost:8082","originRequest":{"noTLSVerify":true}},
        {"hostname":$domain,"path":"/ssgo","service":"http://localhost:8083","originRequest":{"noTLSVerify":true}},
        {"service":"http_status:404"}
      ]
    }
  }')"
  cf_api_call PUT "/accounts/${account_id}/cfd_tunnel/${tunnel_id}/configurations" "$payload" >/dev/null || return 1

  cf_upsert_dns_record_cname "$zone_id" "$domain" "${tunnel_id}.cfargotunnel.com" || return 1

  echo "$tunnel_id" > "$ARGO_TUNNEL_ID_FILE"
  echo "$tunnel_token" > "$ARGO_TOKEN_FILE"
  chmod 600 "$ARGO_TUNNEL_ID_FILE" "$ARGO_TOKEN_FILE" 2>/dev/null || true

  CF_API_ACCOUNT_ID="$account_id"; save_cf_api
  green "Argo Tunnel 已自动创建并下发远程配置"
}

# ========== IP / ISP ==========
country_flag(){
  local cc="${1^^}"; [[ "$cc" =~ ^[A-Z]{2}$ ]] || { echo ""; return; }
  case "${LC_ALL:-${LANG:-}}" in *UTF-8*|*utf8*) ;; *) echo ""; return ;; esac
  local o1 o2 cp1 cp2
  o1=$(printf '%d' "'${cc:0:1}"); o2=$(printf '%d' "'${cc:1:1}")
  cp1=$((0x1F1E6 + o1 - 65)); cp2=$((0x1F1E6 + o2 - 65))
  eval "printf '%s' \$'\\U$(printf '%08X' "$cp1")\\U$(printf '%08X' "$cp2")'"
}
clean_isp(){
  local s="$1"
  s="$(echo "$s" | sed -E 's/^AS(AS)?[0-9]+[[:space:]]+//I')"; s="${s#AS[0-9]* }"
  s="$(echo "$s" | sed -E 's/[[:space:],]+$//; s/^[[:space:],]+//')"
  s="$(echo "$s" | sed -E 's/[[:space:]]+(LLC|Inc\.?|Ltd\.?|Corp\.?|Limited|Company|GmbH|SAS|PLC|Co\.?)$//I')"
  s="$(echo "$s" | sed -E 's/[[:space:],]+$//; s/^[[:space:],]+//')"
  echo "$s"
}
save_ip_cache(){
  mkdir -p "$WORK"
  cat > "$IPCACHE" <<EOF
WAN4=$(printf '%q' "$WAN4")
WAN6=$(printf '%q' "$WAN6")
COUNTRY4=$(printf '%q' "$COUNTRY4")
COUNTRY6=$(printf '%q' "$COUNTRY6")
ISP4=$(printf '%q' "$ISP4")
ISP6=$(printf '%q' "$ISP6")
EMOJI4=$(printf '%q' "$EMOJI4")
EMOJI6=$(printf '%q' "$EMOJI6")
BASE_REGION=$(printf '%q' "$BASE_REGION")
BASE_FULL=$(printf '%q' "$BASE_FULL")
EOF
}
load_ip_cache(){
  [ -f "$IPCACHE" ] || return 1
  . "$IPCACHE" 2>/dev/null || return 1
  [ -n "${WAN4}${WAN6}" ] || return 1
  IP_CHECKED=1
  return 0
}
apply_base_name(){
  local cc isp emo short_isp
  if [ -n "$COUNTRY4" ] || [ -n "$ISP4" ]; then cc="${COUNTRY4^^}"; isp="$ISP4"; emo="$EMOJI4"; else cc="${COUNTRY6^^}"; isp="$ISP6"; emo="$EMOJI6"; fi
  [ -z "$emo" ] && emo="$(country_flag "$cc" 2>/dev/null || true)"
  if [ -n "$isp" ]; then
    short_isp=$(echo "$isp" | awk '{print toupper(substr($1,1,1)) tolower(substr($1,2))}')
    BASE_FULL="${emo} ${cc} ${short_isp}"
  else
    BASE_FULL="${emo} ${cc}"
  fi
  [ -z "$BASE_FULL" ] && BASE_FULL="Node"
}
fill_by_ipinfo_ip(){
  local fam="$1" ip="$2"
  [ -z "$ip" ] && return 1
  local j cc org
  j="$(curl -sf --max-time 6 "https://ipinfo.io/${ip}/json" 2>/dev/null || true)"
  if [ -z "$j" ] || ! echo "$j" | jq -e '.ip' >/dev/null 2>&1; then
    org="$(curl -sf --max-time 5 "https://ipinfo.io/${ip}/org" 2>/dev/null || true)"
    cc="$(curl -sf --max-time 5 "https://ipinfo.io/${ip}/country" 2>/dev/null || true)"
    if [ "$fam" = "4" ]; then
      WAN4="$ip"; COUNTRY4="$cc"; EMOJI4="$(country_flag "$cc" 2>/dev/null || true)"; ISP4="$(clean_isp "$org")"; [ -z "$ISP4" ] && ISP4="unknown"
    else
      WAN6="$ip"; COUNTRY6="$cc"; EMOJI6="$(country_flag "$cc" 2>/dev/null || true)"; ISP6="$(clean_isp "$org")"; [ -z "$ISP6" ] && ISP6="unknown"
    fi
    return 0
  fi
  cc="$(echo "$j" | jq -r '.country // empty' 2>/dev/null || true)"
  org="$(echo "$j" | jq -r '.org // empty' 2>/dev/null || true)"
  if [ "$fam" = "4" ]; then
    WAN4="$(echo "$j" | jq -r '.ip // empty' 2>/dev/null || true)"; COUNTRY4="$cc"; EMOJI4="$(country_flag "$cc" 2>/dev/null || true)"; ISP4="$(clean_isp "$org")"; [ -z "$ISP4" ] && ISP4="unknown"
  else
    WAN6="$(echo "$j" | jq -r '.ip // empty' 2>/dev/null || true)"; COUNTRY6="$cc"; EMOJI6="$(country_flag "$cc" 2>/dev/null || true)"; ISP6="$(clean_isp "$org")"; [ -z "$ISP6" ] && ISP6="unknown"
  fi
}
get_local_ipv6_fallback(){
  local ip6=""
  ip6="$(ip -6 route get 2606:4700:4700::1111 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}' || true)"
  [ -z "$ip6" ] && ip6="$(ip -6 addr show scope global 2>/dev/null | awk '/inet6/{print $2}' | cut -d/ -f1 | grep -v '^fe80:' | head -n1 || true)"
  echo "$ip6"
}
check_ip(){
  [ "${IP_CHECKED:-0}" = "1" ] && return 0
  WAN4=""; WAN6=""; COUNTRY4=""; COUNTRY6=""; ISP4=""; ISP6=""; EMOJI4=""; EMOJI6=""
  local ip4 ip6
  ip4="$(curl -4 -sf --max-time 5 https://api.ipify.org 2>/dev/null || true)"
  [ -n "$ip4" ] && fill_by_ipinfo_ip 4 "$ip4" || true
  ip6="$(curl -6 -sf --max-time 6 https://api64.ipify.org 2>/dev/null || true)"
  if [ -n "$ip6" ]; then
    WAN6="$ip6"; fill_by_ipinfo_ip 6 "$WAN6" || true
  else
    ip6="$(get_local_ipv6_fallback || true)"
    [ -n "$ip6" ] && { WAN6="$ip6"; fill_by_ipinfo_ip 6 "$WAN6" || true; }
  fi
  apply_base_name || true
  IP_CHECKED=1; save_ip_cache || true
  return 0
}
pick_node_host(){ if [ -n "${WAN6:-}" ]; then echo "[${WAN6}]"; elif [ -n "${WAN4:-}" ]; then echo "${WAN4}"; else echo ""; fi; }

# ========== Domain helpers ==========
normalize_domain_item(){ local s="$1"; s="${s#http://}"; s="${s#https://}"; s="${s%%/*}"; s="${s%%:*}"; s="$(echo "$s" | tr '[:upper:]' '[:lower:]' | sed 's/^ *//;s/ *$//;s/^\.*//')"; echo "$s"; }
merge_csv(){ local a="$1" b="$2"; if [ -z "$a" ]; then echo "$b"; return; fi; if [ -z "$b" ]; then echo "$a"; return; fi; echo "${a},${b}"; }
csv_to_json_unique(){
  local d="$1"; local raw_arr=() clean_arr=() item
  IFS=',' read -r -a raw_arr <<< "$d"
  for item in "${raw_arr[@]}"; do
    item="$(normalize_domain_item "$item")"; [ -z "$item" ] && continue; clean_arr+=("$item")
  done
  printf '%s\n' "${clean_arr[@]}" | awk 'NF' | sort -u | jq -Rsc 'split("\n")|map(select(length>0))'
}
build_v6_domains_json(){ csv_to_json_unique "$V6_SITES"; }
yt_mode_str(){ case "$YOUTUBE_MODE" in 2) echo "开启(严格)" ;; *) echo "关闭" ;; esac; }

# ========== Xray core ==========
init_xray_conf(){
  mkdir -p "$WORK"
  [ -f "$XRAY_CONF" ] && return
  cat > "$XRAY_CONF" <<'EOF'
{
  "log": { "access": "/dev/null", "error": "/dev/null", "loglevel": "none" },
  "dns": {
    "servers": [
      { "address": "https+local://1.1.1.1/dns-query", "queryStrategy": "UseIPv4" },
      { "address": "https+local://8.8.8.8/dns-query", "queryStrategy": "UseIPv4" }
    ],
    "queryStrategy": "UseIPv4",
    "enableParallelQuery": true,
    "disableFallback": true,
    "serveStale": true,
    "serveExpiredTTL": 0
  },
  "inbounds": [],
  "outbounds": [
    { "protocol": "freedom", "tag": "direct", "settings": { "domainStrategy": "UseIPv4" } },
    { "protocol": "dns", "tag": "dns-out" }
  ],
  "routing": {
    "rules": [
      { "type": "field", "port": "53", "outboundTag": "dns-out" },
      { "type": "field", "protocol": "dns", "outboundTag": "dns-out" }
    ]
  }
}
EOF
}
ensure_dns_rule(){
  init_xray_conf
  local has_dnsout
  has_dnsout=$(jq '[.outbounds[]?.tag] | contains(["dns-out"])' "$XRAY_CONF" 2>/dev/null || echo false)
  [ "$has_dnsout" = "true" ] || update_xray '.outbounds += [{"protocol":"dns","tag":"dns-out"}]'
  jq -e '.routing' "$XRAY_CONF" >/dev/null 2>&1 || update_xray '.routing={"rules":[]}'
  update_xray 'del(.routing.rules[]? | select(.port=="53" or .protocol=="dns"))'
  update_xray '.routing.rules += [{"type":"field","port":"53","outboundTag":"dns-out"},{"type":"field","protocol":"dns","outboundTag":"dns-out"}]'
}
ensure_geosite(){
  [ -s "${WORK}/geosite.dat" ] && return 0
  yellow "未检测到 geosite.dat，尝试下载..."
  if smart_download "${WORK}/geosite.dat" \
    "https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat" 1000000; then
    green "geosite.dat 已就绪"; return 0
  fi
  red "geosite.dat 下载失败"; return 1
}
xray_uuid(){
  if [ -f "$XRAY_CONF" ]; then
    local u; u=$(jq -r '(first(.inbounds[]? | select(.protocol=="vless") | .settings.clients[0].id) // empty)' "$XRAY_CONF" 2>/dev/null || true)
    [ -n "$u" ] && { echo "$u"; return; }
  fi
  echo "$UUID_FALLBACK"
}
set_xray_uuid(){
  local u="$1"
  [ -f "$XRAY_CONF" ] || { red "xray未安装"; return 1; }

  # 修改所有 VLESS 入站，包括 Argo / Origin / Reality
  update_xray --arg uuid "$u" '
    (.inbounds[]?
      | select(.protocol=="vless")
      | .settings.clients[0].id) |= $uuid
  '

  # 同步 Reality 链接缓存列表，否则查看 Reality 链接时仍显示旧 UUID
  if [ -f "$REALITY_LIST" ]; then
    if jq --arg uuid "$u" 'map(.uuid=$uuid)' "$REALITY_LIST" > "${REALITY_LIST}.tmp"; then
      mv "${REALITY_LIST}.tmp" "$REALITY_LIST"
    else
      rm -f "${REALITY_LIST}.tmp"
      yellow "Reality 列表 UUID 同步失败，请检查: $REALITY_LIST"
    fi
  fi

  if [ -x "$XRAY_BIN" ] && ! "$XRAY_BIN" run -test -c "$XRAY_CONF" >/tmp/xray_uuid_check.log 2>&1; then
    red "UUID 修改后配置校验失败，请检查配置"
    tail -n 80 /tmp/xray_uuid_check.log 2>/dev/null || true
    return 1
  fi

  svc restart xray
  green "UUID已全局更新: $u"
}

install_xray(){
  ensure_deps || return 1; mkdir -p "$WORK"; init_xray_conf; ensure_dns_rule
  if [ ! -x "$XRAY_BIN" ]; then
    local arch url
    arch="$(detect_xray_arch)"; [ -z "$arch" ] && { red "架构不支持Xray"; return 1; }
    url="https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-${arch}.zip"
    smart_download "${WORK}/xray.zip" "$url" 5000000 || { red "下载Xray失败"; return 1; }
    unzip -o "${WORK}/xray.zip" -d "${WORK}/" >/dev/null 2>&1 || return 1
    chmod +x "$XRAY_BIN"; rm -f "${WORK}/xray.zip" "${WORK}/README.md" "${WORK}/LICENSE"
  fi
  if ! service_exists xray; then
    if is_alpine; then
      cat > /etc/init.d/xray <<EOF
#!/sbin/openrc-run
description="Xray Service"
command="${XRAY_BIN}"
command_args="run -c ${XRAY_CONF}"
command_background=true
pidfile="/var/run/xray.pid"
EOF
      chmod +x /etc/init.d/xray
    else
      cat > /etc/systemd/system/xray.service <<EOF
[Unit]
Description=Xray Service
After=network.target
[Service]
ExecStart=${XRAY_BIN} run -c ${XRAY_CONF}
Restart=always
[Install]
WantedBy=multi-user.target
EOF
    fi
    svc enable xray
  fi
  svc restart xray; green "Xray 安装完成"
}

update_xray_core(){
  ensure_deps || return 1
  mkdir -p "$WORK"
  local arch url
  arch="$(detect_xray_arch)"; [ -z "$arch" ] && { red "架构不支持Xray"; return 1; }
  url="https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-${arch}.zip"
  smart_download "${WORK}/xray_update.zip" "$url" 5000000 || { red "下载Xray失败"; return 1; }
  unzip -o "${WORK}/xray_update.zip" -d "${WORK}/" >/dev/null 2>&1 || { red "解压失败"; return 1; }
  chmod +x "$XRAY_BIN"
  rm -f "${WORK}/xray_update.zip" "${WORK}/README.md" "${WORK}/LICENSE"
  if [ -f "$XRAY_CONF" ] && ! "$XRAY_BIN" run -test -c "$XRAY_CONF" >/tmp/xray_update_check.log 2>&1; then
    red "更新后配置校验失败"
    tail -n 60 /tmp/xray_update_check.log 2>/dev/null || true
    return 1
  fi
  svc restart xray
  green "Xray 更新完成"
}

uninstall_xray_only(){
  cls
  echo -e "${C_WARN}=========== 卸载 Xray ===========${C_RST}"
  echo "1) 卸载（保留配置）"
  echo "2) 完全卸载"
  echo "0) 取消"
  prompt "请选择: " m
  case "$m" in
    1)
      svc stop xray; svc disable xray
      rm -f /etc/init.d/xray /etc/systemd/system/xray.service "$XRAY_BIN"
      command -v systemctl >/dev/null 2>&1 && systemctl daemon-reload >/dev/null 2>&1 || true
      green "Xray已卸载（保留配置）"
      ;;
    2)
      svc stop xray; svc disable xray
      rm -f /etc/init.d/xray /etc/systemd/system/xray.service
      rm -f "$XRAY_BIN" "$XRAY_CONF" "$HY2_LIST" "$REALITY_LIST" "$CF_MODE_CONF"
      command -v systemctl >/dev/null 2>&1 && systemctl daemon-reload >/dev/null 2>&1 || true
      green "Xray已完全卸载"
      ;;
    *)
      yellow "已取消"
      ;;
  esac
}

# ========== Outbound apply ==========
apply_policy_xray(){
  [ -f "$XRAY_CONF" ] || return 0; ensure_dns_rule
  update_xray '
    .outbounds = (
      [
        {"protocol":"freedom","tag":"direct-v4","settings":{"domainStrategy":"UseIPv4"}},
        {"protocol":"freedom","tag":"direct-v6","settings":{"domainStrategy":"UseIPv6"}},
        {"protocol":"blackhole","tag":"block-v4"}
      ]
      + (
          [ .outbounds[]? | select(.tag=="dns-out") ]
          | if length>0 then . else [{"protocol":"dns","tag":"dns-out"}] end
        )
      + [ .outbounds[]? | select(.tag!="direct" and .tag!="direct-v4" and .tag!="direct-v6" and .tag!="block-v4" and .tag!="dns-out") ]
    )'
  update_xray 'del(.routing.rules[]? | select(
  .tag=="v6-strict-rule" or
  .tag=="v6-strict-route-rule" or
  .tag=="v6-strict-reject-rule" or
  .tag=="v6-geosite-strict-route-rule" or
  .tag=="v6-geosite-strict-reject-rule"
))'
  local v6_domains
  v6_domains="$(build_v6_domains_json)"
  if [ "$(echo "$v6_domains" | jq 'length')" -gt 0 ]; then
    update_xray --argjson d "$v6_domains" \
      '.routing.rules += [{
        "type":"field",
        "domain":($d|map("domain:"+.)),
        "ip":["0.0.0.0/0"],
        "outboundTag":"block-v4",
        "tag":"v6-strict-reject-rule"
      }]'

    update_xray --argjson d "$v6_domains" \
      '.routing.rules += [{
        "type":"field",
        "domain":($d|map("domain:"+.)),
        "outboundTag":"direct-v6",
        "tag":"v6-strict-route-rule"
      }]'
  fi
  if [ "$YOUTUBE_MODE" = "2" ]; then
    if ensure_geosite; then
      update_xray '.routing.rules += [{"type":"field","domain":["geosite:youtube"],"ip":["0.0.0.0/0"],"outboundTag":"block-v4","tag":"v6-geosite-strict-reject-rule"}]'
      update_xray '.routing.rules += [{"type":"field","domain":["geosite:youtube"],"outboundTag":"direct-v6","tag":"v6-geosite-strict-route-rule"}]'
    else
      red "geosite 不可用，YouTube 严格规则未应用"
    fi
  fi
}
apply_policy_all(){
  apply_policy_xray || true
  if [ -x "$XRAY_BIN" ] && [ -f "$XRAY_CONF" ]; then
    if ! "$XRAY_BIN" run -test -c "$XRAY_CONF" >/tmp/xray_check_apply.log 2>&1; then
      red "Xray 配置校验失败，已跳过重启"
      tail -n 50 /tmp/xray_check_apply.log 2>/dev/null || true
    else
      service_exists xray && svc restart xray
    fi
  fi
  green "出站规则已应用（Xray）"
}
ask_enable_youtube_strict(){
  local yn
  prompt "是否开启 YouTube 严格V6出站? (1=关闭 2=开启(严格)，默认1): " yn
  case "$yn" in 2) YOUTUBE_MODE=2 ;; *) YOUTUBE_MODE=1 ;; esac
  save_outbound; apply_policy_all || true
}

# ========== CF加速模式 ==========
cf_remove_origin_inbounds(){
  [ -f "$XRAY_CONF" ] || return 0
  update_xray --argjson p1 "$ORIGIN_VLESS_WS_PORT" --argjson p2 "$ORIGIN_VLESS_XHTTP_PORT" --argjson p3 "$ORIGIN_SS_WS_PORT" \
    'del(.inbounds[]? | select(.port==$p1 or .port==$p2 or .port==$p3))'
}
cf_remove_argo_inbounds(){
  [ -f "$XRAY_CONF" ] || return 0
  update_xray 'del(.inbounds[]? | select(.port==8081 or .port==8082 or .port==8083))'
}

setup_cf_origin(){
  install_xray || return 1
  ensure_dns_rule || return 1
  cf_bootstrap_once "CF回源"

  local domain ss_pass mc ss_method uuid ws xh ss xh_json
  prompt "CF回源域名(用于SNI/Host): " domain
  [ -z "$domain" ] && { red "域名不能为空"; return 1; }

  prompt "SS密码(回车随机UUID): " ss_pass
  [ -z "$ss_pass" ] && ss_pass="$(gen_uuid)"
  prompt "SS加密(1=aes-128-gcm 2=aes-256-gcm，默认1): " mc
  [ -z "$mc" ] && mc=1
  ss_method="aes-128-gcm"; [ "$mc" = "2" ] && ss_method="aes-256-gcm"

  uuid="$(xray_uuid)"

  cf_remove_argo_inbounds
  cf_remove_origin_inbounds

  ws='{"port":'"${ORIGIN_VLESS_WS_PORT}"',"listen":"0.0.0.0","protocol":"vless","settings":{"clients":[{"id":"'"${uuid}"'"}],"decryption":"none"},"streamSettings":{"network":"ws","security":"none","wsSettings":{"path":"/argo","host":"'"${domain}"'"}}},"sniffing":{"enabled":true,"destOverride":["http","tls","quic"],"routeOnly":false}}'
  xh_json="$(jq -nc --arg uuid "$uuid" --arg mode "$XHTTP_MODE" --argjson extra "$XHTTP_EXTRA_JSON" --arg host "$domain" \
    '{"port":'"${ORIGIN_VLESS_XHTTP_PORT}"',"listen":"0.0.0.0","protocol":"vless","settings":{"clients":[{"id":$uuid}],"decryption":"none"},"streamSettings":{"network":"xhttp","security":"none","xhttpSettings":{"host":$host,"path":"/xgo","mode":$mode,"extra":$extra}},"sniffing":{"enabled":true,"destOverride":["http","tls","quic"],"routeOnly":false}}')"
  ss='{"port":'"${ORIGIN_SS_WS_PORT}"',"listen":"0.0.0.0","protocol":"shadowsocks","settings":{"method":"'"${ss_method}"'","password":"'"${ss_pass}"'","network":"tcp,udp"},"streamSettings":{"network":"ws","security":"none","wsSettings":{"path":"/ssgo","host":"'"${domain}"'"}}},"sniffing":{"enabled":true,"destOverride":["http","tls","quic"],"routeOnly":false}}'

  update_xray --argjson ws "$ws" --argjson xh "$xh_json" --argjson ss "$ss" '.inbounds += [$ws,$xh,$ss]'

  if ! "$XRAY_BIN" run -test -c "$XRAY_CONF" >/tmp/xray_cf_origin_check.log 2>&1; then
    red "Xray 配置校验失败"
    tail -n 80 /tmp/xray_cf_origin_check.log 2>/dev/null || true
    cf_remove_origin_inbounds
    return 1
  fi

  open_port "$ORIGIN_VLESS_WS_PORT" tcp || yellow "请手动放行 ${ORIGIN_VLESS_WS_PORT}/tcp"
  open_port "$ORIGIN_VLESS_XHTTP_PORT" tcp || yellow "请手动放行 ${ORIGIN_VLESS_XHTTP_PORT}/tcp"
  open_port "$ORIGIN_SS_WS_PORT" tcp || yellow "请手动放行 ${ORIGIN_SS_WS_PORT}/tcp"

  echo "$domain" > "$ARGO_DOMAIN"

  if service_exists tunnel-argo; then
    svc stop tunnel-argo || true
  fi

  load_cf_api >/dev/null 2>&1 || true
  if [ -n "${CF_API_TOKEN:-}" ]; then
    cf_apply_origin_rules_for_domain "$domain" || yellow "Origin Rules 自动配置失败，请手动到 Cloudflare 配置"
    cf_apply_xhttp_cache_bypass_for_domain "$domain" || yellow "Cache Rules 自动配置失败，请手动到 Cloudflare 配置"
  else
    yellow "未配置全局 Cloudflare API Token，已跳过 Origin Rules / Cache Rules 自动配置"
  fi

  svc restart xray
  CF_MODE="origin"; save_cf_mode
  ask_enable_youtube_strict
  green "CF加速已配置为 端口回源 模式（${ORIGIN_VLESS_WS_PORT}/${ORIGIN_VLESS_XHTTP_PORT}/${ORIGIN_SS_WS_PORT}）"
}

# ========== Argo ==========
install_cloudflared(){
  mkdir -p "$WORK"
  local arch url tmp bin
  bin="${WORK}/argo"
  arch="$(detect_cloudflared_arch)"; [ -z "$arch" ] && { red "架构不支持 cloudflared"; return 1; }
  case "$arch" in
    amd64) url="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64" ;;
    arm64) url="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm64" ;;
    386)   url="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-386" ;;
    arm)   url="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm" ;;
    *) red "未知架构: $arch"; return 1 ;;
  esac
  if [ -x "$bin" ] && "$bin" --version >/dev/null 2>&1; then green "cloudflared 已存在，跳过下载"; return 0; fi
  tmp="${WORK}/argo.tmp"
  smart_download "$tmp" "$url" 10000000 || { red "下载 cloudflared 失败"; rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$bin"; chmod +x "$bin"
  "$bin" --version >/dev/null 2>&1 || { red "cloudflared 校验失败"; rm -f "$bin"; return 1; }
  green "cloudflared 安装完成"
}
write_argo_service(){
  local svcname="tunnel-argo"
  cat > "${WORK}/argo_start.sh" <<EOF
#!/bin/sh
TOKEN=\$(cat "${ARGO_TOKEN_FILE}" 2>/dev/null)
exec ${WORK}/argo tunnel --edge-ip-version auto --no-autoupdate --metrics 127.0.0.1:2000 run --token "\${TOKEN}"
EOF
  chmod +x "${WORK}/argo_start.sh"
  if is_alpine; then
    cat > /etc/init.d/${svcname} <<EOF
#!/sbin/openrc-run
description="Cloudflare Tunnel"
command="${WORK}/argo_start.sh"
command_background=true
pidfile="/var/run/${svcname}.pid"
EOF
    chmod +x /etc/init.d/${svcname}
  else
    cat > /etc/systemd/system/${svcname}.service <<EOF
[Unit]
Description=Cloudflare Tunnel
After=network.target
[Service]
ExecStart=${WORK}/argo_start.sh
Restart=always
RestartSec=3
[Install]
WantedBy=multi-user.target
EOF
  fi
  svc enable "$svcname"
}
install_argo(){
  install_xray || return 1
  ensure_dns_rule || return 1
  install_cloudflared || return 1
  cf_bootstrap_once "Argo"

  local domain ss_pass mc ss_method uuid
  prompt "Argo域名: " domain; [ -z "$domain" ] && { red "不能为空"; return 1; }
  prompt "SS密码(回车随机UUID): " ss_pass; [ -z "$ss_pass" ] && ss_pass="$(gen_uuid)"
  prompt "SS加密(1=aes-128-gcm 2=aes-256-gcm，默认1): " mc; [ -z "$mc" ] && mc=1; ss_method="aes-128-gcm"; [ "$mc" = "2" ] && ss_method="aes-256-gcm"

  cf_require_token || return 1
  cf_create_argo_tunnel_remote "$domain" || return 1

  echo "$domain" > "$ARGO_DOMAIN"
  uuid="$(xray_uuid)"
  cf_remove_origin_inbounds
  cf_remove_argo_inbounds

  local ws xh ss
  ws='{"port":8081,"listen":"127.0.0.1","protocol":"vless","settings":{"clients":[{"id":"'"${uuid}"'"}],"decryption":"none"},"streamSettings":{"network":"ws","security":"none","wsSettings":{"path":"/argo"}},"sniffing":{"enabled":true,"destOverride":["http","tls","quic"],"routeOnly":false}}'
  xh="$(jq -nc --arg uuid "$uuid" --arg mode "$XHTTP_MODE" --argjson extra "$XHTTP_EXTRA_JSON" \
     '{"port":8082,"listen":"127.0.0.1","protocol":"vless","settings":{"clients":[{"id":$uuid}],"decryption":"none"},"streamSettings":{"network":"xhttp","security":"none","xhttpSettings":{"host":"","path":"/xgo","mode":$mode,"extra":$extra}},"sniffing":{"enabled":true,"destOverride":["http","tls","quic"],"routeOnly":false}}')"
  ss='{"port":8083,"listen":"127.0.0.1","protocol":"shadowsocks","settings":{"method":"'"${ss_method}"'","password":"'"${ss_pass}"'","network":"tcp,udp"},"streamSettings":{"network":"ws","security":"none","wsSettings":{"path":"/ssgo"}},"sniffing":{"enabled":true,"destOverride":["http","tls","quic"],"routeOnly":false}}'

  update_xray --argjson ws "$ws" --argjson xh "$xh" --argjson ss "$ss" '.inbounds += [$ws,$xh,$ss]'

  if ! "$XRAY_BIN" run -test -c "$XRAY_CONF" >/tmp/xray_argo_check.log 2>&1; then
    red "Xray 配置校验失败"
    tail -n 80 /tmp/xray_argo_check.log 2>/dev/null || true
    cf_remove_argo_inbounds
    return 1
  fi

  [ -x "${WORK}/argo" ] || { red "cloudflared 不存在: ${WORK}/argo"; return 1; }

  write_argo_service
  svc restart xray
  svc restart tunnel-argo

  cf_apply_xhttp_cache_bypass_for_domain "$domain" || yellow "Cache Rules 自动配置失败，请手动配置 XHTTP 绕过缓存"

  CF_MODE="argo"; save_cf_mode
  ask_enable_youtube_strict
  green "Argo 配置完成（已使用 Token 自动创建 Tunnel）"
}

configure_cf_accel(){
  while true; do
    cls
    echo -e "${C_WARN}=========== 配置CF加速 ===========${C_RST}"
    echo -e "当前模式: \033[1;36m$(cf_mode_display)\033[0m"
    echo "-------------------------------------"
    menu_item_auto "1" "Argo隧道"
    menu_item_auto "2" "端口回源"
    menu_item_auto "0" "返回"
    echo "====================================="
    prompt "请选择: " m
    case "$m" in
      1) install_argo; pause ;;
      2) setup_cf_origin; pause ;;
      0) return ;;
      *) red "无效"; pause ;;
    esac
  done
}

uninstall_argo(){
  svc stop tunnel-argo; svc disable tunnel-argo
  rm -f /etc/init.d/tunnel-argo /etc/systemd/system/tunnel-argo.service "${WORK}/argo_start.sh" "${WORK}/argo"
  rm -f "$ARGO_DOMAIN" "$ARGO_YML" "$ARGO_JSON" "$ARGO_TOKEN_FILE" "$ARGO_TUNNEL_ID_FILE"

  if [ -f "$XRAY_CONF" ]; then
    cf_remove_argo_inbounds
    cf_remove_origin_inbounds
    svc restart xray
  fi

  command -v systemctl >/dev/null 2>&1 && systemctl daemon-reload >/dev/null 2>&1 || true
  CF_MODE="argo"; save_cf_mode
  green "Argo/端口回源 已卸载"
}

# ========== HY2 multi ==========
init_hy2_list(){
  mkdir -p "$WORK"
  [ -f "$HY2_LIST" ] || echo '[]' > "$HY2_LIST"
}
hy2_port_exists_in_conf(){
  local p="$1"
  jq --argjson p "$p" '[.inbounds[]? | select((.protocol=="hysteria" or .protocol=="hysteria2") and .port==$p)] | length' "$XRAY_CONF" 2>/dev/null | grep -qv '^0$'
}
hy2_random_free_port(){
  local old="${1:-0}" p
  while true; do
    p=$(( ((RANDOM << 15) | RANDOM) % 65535 + 1 ))
    [ "$old" -gt 0 ] && [ "$p" -eq "$old" ] && continue
    if ss -tuln 2>/dev/null | grep -q ":${p} "; then
      continue
    fi
    if hy2_port_exists_in_conf "$p"; then
      continue
    fi
    echo "$p"
    return
  done
}

issue_cert_cf(){
  local d="$1" token="${2:-}" cert_dir="${3:-$TLS_DIR_HY2}"
  local crt="${cert_dir}/${d}.crt" key="${cert_dir}/${d}.key"
  mkdir -p "$cert_dir"
  if [ -s "$crt" ] && [ -s "$key" ]; then
    if openssl x509 -in "$crt" -noout -checkend $((30*24*3600)) >/dev/null 2>&1; then
      green "证书已存在且有效(>30天): $d"; return 0
    else
      yellow "证书即将过期或已过期，开始续签: $d"
    fi
  fi
  [ -n "$token" ] || { cf_require_token || return 1; token="$CF_API_TOKEN"; }
  ensure_acme || return 1
  export CF_Token="$token"
  yellow "申请证书: $d"
  "$HOME/.acme.sh/acme.sh" --set-default-ca --server letsencrypt >/dev/null 2>&1 || true
  "$HOME/.acme.sh/acme.sh" --issue -d "$d" --dns dns_cf -k ec-256 >/tmp/acme_issue.log 2>&1 || { red "签发失败"; tail -n 80 /tmp/acme_issue.log 2>/dev/null || true; return 1; }
  "$HOME/.acme.sh/acme.sh" --installcert -d "$d" --fullchainpath "$crt" --keypath "$key" --ecc >/tmp/acme_installcert.log 2>&1 || true
  [ -s "$crt" ] && [ -s "$key" ] || { red "安装证书失败"; tail -n 80 /tmp/acme_installcert.log 2>/dev/null || true; return 1; }
  green "证书安装成功"
}
issue_cert_selfsigned(){
  local d="$1" cert_dir="${2:-$TLS_DIR_HY2}"
  local crt="${cert_dir}/${d}.crt" key="${cert_dir}/${d}.key"
  mkdir -p "$cert_dir"
  if [ -s "$crt" ] && [ -s "$key" ]; then
    if openssl x509 -in "$crt" -noout -checkend $((30*24*3600)) >/dev/null 2>&1; then
      green "自签证书已存在且有效(>30天): $d"; return 0
    else
      yellow "自签证书即将过期或已过期，重新生成: $d"
    fi
  fi
  openssl req -x509 -nodes -newkey rsa:2048 -sha256 -days 3650 \
    -subj "/CN=${d}" \
    -keyout "$key" -out "$crt" >/tmp/selfsign_issue.log 2>&1 || {
    red "自签证书生成失败"
    tail -n 80 /tmp/selfsign_issue.log 2>/dev/null || true
    return 1
  }
  [ -s "$crt" ] && [ -s "$key" ] || { red "自签证书文件异常"; return 1; }
  green "自签证书生成成功: $d"
}
hy2_build_inbound_json(){
  local tag="$1" port="$2" auth="$3" domain="$4" cert_file="$5" key_file="$6" obfs="$7"
  if [ -n "$obfs" ]; then
    jq -nc \
      --arg tag "$tag" \
      --argjson p "$port" \
      --arg auth "$auth" \
      --arg obfs "$obfs" \
      --arg domain "$domain" \
      --arg crt "$cert_file" \
      --arg key "$key_file" \
'{
  "tag":$tag,
  "listen":"::",
  "port":$p,
  "protocol":"hysteria",
  "settings":{"version":2,"clients":[{"auth":$auth,"email":"hy2@local"}]},
  "streamSettings":{
    "network":"hysteria",
    "security":"tls",
    "tlsSettings":{"alpn":["h3"],"certificates":[{"certificateFile":$crt,"keyFile":$key}],"serverName":$domain},
    "finalmask":{
      "udp":[{"type":"salamander","settings":{"password":$obfs}}],
      "quicParams":{"congestion":"bbr","bbrProfile":"standard","maxIdleTimeout":30,"keepAlivePeriod":10,"disablePathMTUDiscovery":false}
    }
  },
  "sniffing":{"enabled":true,"destOverride":["http","tls","quic"],"routeOnly":false}
}'
  else
    jq -nc \
      --arg tag "$tag" \
      --argjson p "$port" \
      --arg auth "$auth" \
      --arg domain "$domain" \
      --arg crt "$cert_file" \
      --arg key "$key_file" \
'{
  "tag":$tag,
  "listen":"::",
  "port":$p,
  "protocol":"hysteria",
  "settings":{"version":2,"clients":[{"auth":$auth,"email":"hy2@local"}]},
  "streamSettings":{
    "network":"hysteria",
    "security":"tls",
    "tlsSettings":{"alpn":["h3"],"certificates":[{"certificateFile":$crt,"keyFile":$key}],"serverName":$domain},
    "finalmask":{
      "quicParams":{"congestion":"bbr","bbrProfile":"standard","maxIdleTimeout":30,"keepAlivePeriod":10,"disablePathMTUDiscovery":false}
    }
  },
  "sniffing":{"enabled":true,"destOverride":["http","tls","quic"],"routeOnly":false}
}'
  fi
}
hy2_add_list_entry(){
  local tag="$1" port="$2" domain="$3" auth="$4" up="$5" down="$6" obfs="$7" cert_mode="$8"
  init_hy2_list
  jq --arg tag "$tag" --argjson port "$port" --arg domain "$domain" --arg auth "$auth" \
     --argjson up "$up" --argjson down "$down" --arg obfs "$obfs" --arg cert_mode "$cert_mode" \
     '. += [{"tag":$tag,"port":$port,"domain":$domain,"auth":$auth,"up":$up,"down":$down,"obfs":$obfs,"cert_mode":$cert_mode}]' \
     "$HY2_LIST" > "${HY2_LIST}.tmp" && mv "${HY2_LIST}.tmp" "$HY2_LIST"
}
hy2_update_list_entry_by_port(){
  local old_port="$1" new_tag="$2" new_port="$3" domain="$4" auth="$5" up="$6" down="$7" obfs="$8" cert_mode="$9"
  jq --argjson oldp "$old_port" --arg tag "$new_tag" --argjson p "$new_port" --arg domain "$domain" --arg auth "$auth" \
     --argjson up "$up" --argjson down "$down" --arg obfs "$obfs" --arg cert_mode "$cert_mode" \
     'map(if .port==$oldp then .tag=$tag | .port=$p | .domain=$domain | .auth=$auth | .up=$up | .down=$down | .obfs=$obfs | .cert_mode=$cert_mode else . end)' \
     "$HY2_LIST" > "${HY2_LIST}.tmp" && mv "${HY2_LIST}.tmp" "$HY2_LIST"
}
hy2_del_by_port(){
  local p="$1"
  update_xray --argjson p "$p" 'del(.inbounds[]? | select((.protocol=="hysteria" or .protocol=="hysteria2") and .port==$p))'
  init_hy2_list
  jq --argjson p "$p" 'map(select(.port != $p))' "$HY2_LIST" > "${HY2_LIST}.tmp" && mv "${HY2_LIST}.tmp" "$HY2_LIST"
}
hy2_list_show_table(){
  init_hy2_list
  local list
  list="$(jq -c '.[]' "$HY2_LIST" 2>/dev/null || true)"
  if [ -z "$list" ]; then
    echo -e "当前: ${C_BAD}未配置${C_RST}"
    return
  fi

  echo "------------------------------"
  echo " 序号 | 端口"
  echo "------------------------------"

  local i=1
  while IFS= read -r one; do
    [ -z "$one" ] && continue
    local p
    p="$(echo "$one" | jq -r '.port')"
    printf " %-4s| %s\n" "$i" "$p"
    i=$((i+1))
  done <<< "$list"
}

hy2_pick_by_index(){
  local idx="$1"
  init_hy2_list
  jq -c ".[$((idx-1))] // empty" "$HY2_LIST" 2>/dev/null || true
}

configure_hy2_add(){
  install_xray || return 1; ensure_dns_rule || return 1; init_hy2_list
  cf_bootstrap_once "HY2"
  local cert_mode domain port auth obfs prof up down cert_mode_saved cert_file key_file tag
  prompt "证书模式(1=本机自签 2=CF令牌签发，默认1): " cert_mode
  [ -z "${cert_mode:-}" ] && cert_mode=1; [[ "$cert_mode" =~ ^[12]$ ]] || cert_mode=1
  if [ "$cert_mode" = "1" ]; then
    prompt "HY2伪装域名(回车默认 ${HY2_SELF_SNI_DEFAULT}): " domain
    [ -z "$domain" ] && domain="$HY2_SELF_SNI_DEFAULT"
    issue_cert_selfsigned "$domain" "$TLS_DIR_HY2" || return 1
    cert_mode_saved="self"
  else
    prompt "HY2域名: " domain; [ -z "$domain" ] && { red "域名不能为空"; return 1; }
    issue_cert_cf "$domain" "" "$TLS_DIR_HY2" || return 1
    cert_mode_saved="cf"
  fi
  cert_file="${TLS_DIR_HY2}/${domain}.crt"; key_file="${TLS_DIR_HY2}/${domain}.key"

  prompt "HY2端口(回车随机): " port
  if [ -z "$port" ]; then
    port="$(hy2_random_free_port 0)"
  else
    [[ "$port" =~ ^[0-9]+$ ]] || { red "端口无效"; return 1; }
    [ "$port" -ge 1 ] && [ "$port" -le 65535 ] || { red "端口越界(1-65535)"; return 1; }
    if hy2_port_exists_in_conf "$port"; then red "端口已被HY2占用"; return 1; fi
    if ss -tuln 2>/dev/null | grep -q ":${port} "; then yellow "警告：系统检测该端口可能被占用"; fi
  fi

  prompt "HY2认证AUTH(回车随机UUID): " auth; [ -z "$auth" ] && auth="$(gen_uuid)"
  prompt "HY2混淆密码OBFS(回车留空=不启用混淆): " obfs

  echo "带宽档位: 1.默认(50/250 Mbps) 2.自定义"
  prompt "选择(默认1): " prof
  case "$prof" in
    2)
      prompt "上行Mbps(默认50): " up
      prompt "下行Mbps(默认250): " down
      [ -z "$up" ] && up=50; [ -z "$down" ] && down=250
      [[ "$up" =~ ^[0-9]+$ ]] || up=50
      [[ "$down" =~ ^[0-9]+$ ]] || down=250
      ;;
    *)
      up=50; down=250
      ;;
  esac

  tag="hy2-${port}"
  local ib
  ib="$(hy2_build_inbound_json "$tag" "$port" "$auth" "$domain" "$cert_file" "$key_file" "$obfs")"
  update_xray --argjson ib "$ib" '.inbounds += [$ib]'

  if ! "$XRAY_BIN" run -test -c "$XRAY_CONF" >/tmp/xray_hy2_add_check.log 2>&1; then
    red "Xray 配置校验失败"
    tail -n 80 /tmp/xray_hy2_add_check.log 2>/dev/null || true
    update_xray --argjson p "$port" 'del(.inbounds[]? | select((.protocol=="hysteria" or .protocol=="hysteria2") and .port==$p))'
    return 1
  fi

  open_port "$port" udp || yellow "防火墙自动放行失败，请手动放行 ${port}/udp"
  hy2_add_list_entry "$tag" "$port" "$domain" "$auth" "$up" "$down" "$obfs" "$cert_mode_saved"
  svc restart xray
  green "HY2实例添加成功: 端口 ${port}"
}

configure_hy2_edit(){
  init_hy2_list
  local cnt; cnt="$(jq 'length' "$HY2_LIST" 2>/dev/null || echo 0)"
  [ "${cnt:-0}" -gt 0 ] || { red "无可修改实例"; return 1; }

  hy2_list_show_table
  local idx
  prompt "选择序号(0取消): " idx
  [[ "$idx" =~ ^[0-9]+$ ]] || { red "输入无效"; return 1; }
  [ "$idx" -eq 0 ] && return 0
  [ "$idx" -ge 1 ] && [ "$idx" -le "$cnt" ] || { red "序号越界"; return 1; }

  local one old_port old_domain old_auth old_up old_down old_obfs old_cert_mode
  one="$(hy2_pick_by_index "$idx")"
  [ -n "$one" ] || { red "读取失败"; return 1; }

  old_port="$(echo "$one" | jq -r '.port')"
  old_domain="$(echo "$one" | jq -r '.domain')"
  old_auth="$(echo "$one" | jq -r '.auth')"
  old_up="$(echo "$one" | jq -r '.up')"
  old_down="$(echo "$one" | jq -r '.down')"
  old_obfs="$(echo "$one" | jq -r '.obfs')"
  old_cert_mode="$(echo "$one" | jq -r '.cert_mode')"

  local new_auth new_obfs new_up new_down
  green "当前: 端口=$old_port 域名=$old_domain 证书=$old_cert_mode"
  prompt "新AUTH(留空不变): " new_auth
  prompt "新OBFS(留空=不变，输入 none=清空): " new_obfs
  prompt "新上行Mbps(留空不变): " new_up
  prompt "新下行Mbps(留空不变): " new_down

  [ -z "$new_auth" ] && new_auth="$old_auth"
  if [ "$new_obfs" = "none" ]; then new_obfs=""
  elif [ -z "$new_obfs" ]; then new_obfs="$old_obfs"
  fi
  [ -z "$new_up" ] && new_up="$old_up"
  [ -z "$new_down" ] && new_down="$old_down"
  [[ "$new_up" =~ ^[0-9]+$ ]] || new_up=50
  [[ "$new_down" =~ ^[0-9]+$ ]] || new_down=250

  local cert_file key_file tag ib
  cert_file="${TLS_DIR_HY2}/${old_domain}.crt"
  key_file="${TLS_DIR_HY2}/${old_domain}.key"
  [ -s "$cert_file" ] && [ -s "$key_file" ] || { red "证书文件缺失，无法修改"; return 1; }

  tag="hy2-${old_port}"
  ib="$(hy2_build_inbound_json "$tag" "$old_port" "$new_auth" "$old_domain" "$cert_file" "$key_file" "$new_obfs")"

  update_xray --argjson p "$old_port" 'del(.inbounds[]? | select((.protocol=="hysteria" or .protocol=="hysteria2") and .port==$p))'
  update_xray --argjson ib "$ib" '.inbounds += [$ib]'

  if ! "$XRAY_BIN" run -test -c "$XRAY_CONF" >/tmp/xray_hy2_edit_check.log 2>&1; then
    red "配置校验失败，修改未生效"
    tail -n 80 /tmp/xray_hy2_edit_check.log 2>/dev/null || true
    return 1
  fi

  hy2_update_list_entry_by_port "$old_port" "$tag" "$old_port" "$old_domain" "$new_auth" "$new_up" "$new_down" "$new_obfs" "$old_cert_mode"
  svc restart xray
  green "HY2实例修改成功"
}

configure_hy2_delete(){
  init_hy2_list
  local cnt; cnt="$(jq 'length' "$HY2_LIST" 2>/dev/null || echo 0)"
  [ "${cnt:-0}" -gt 0 ] || { red "无可删除实例"; return 1; }
  hy2_list_show_table
  local idx
  prompt "选择序号删除(0取消): " idx
  [[ "$idx" =~ ^[0-9]+$ ]] || { red "输入无效"; return 1; }
  [ "$idx" -eq 0 ] && return 0
  [ "$idx" -ge 1 ] && [ "$idx" -le "$cnt" ] || { red "序号越界"; return 1; }

  local one p
  one="$(hy2_pick_by_index "$idx")"
  p="$(echo "$one" | jq -r '.port')"
  [ -n "$p" ] || { red "读取端口失败"; return 1; }

  hy2_del_by_port "$p"
  if ! "$XRAY_BIN" run -test -c "$XRAY_CONF" >/tmp/xray_hy2_del_check.log 2>&1; then
    red "配置校验失败，删除可能未生效"
    tail -n 60 /tmp/xray_hy2_del_check.log 2>/dev/null || true
    return 1
  fi
  svc restart xray
  green "已删除HY2实例: 端口 $p"
}

configure_hy2_reinstall_port(){
  init_hy2_list
  local cnt; cnt="$(jq 'length' "$HY2_LIST" 2>/dev/null || echo 0)"
  [ "${cnt:-0}" -gt 0 ] || { red "无可重装实例"; return 1; }

  hy2_list_show_table
  local idx
  prompt "选择要重装换端口的序号(0取消): " idx
  [[ "$idx" =~ ^[0-9]+$ ]] || { red "输入无效"; return 1; }
  [ "$idx" -eq 0 ] && return 0
  [ "$idx" -ge 1 ] && [ "$idx" -le "$cnt" ] || { red "序号越界"; return 1; }

  local one old_port domain auth up down obfs cert_mode
  one="$(hy2_pick_by_index "$idx")"
  old_port="$(echo "$one" | jq -r '.port')"
  domain="$(echo "$one" | jq -r '.domain')"
  auth="$(echo "$one" | jq -r '.auth')"
  up="$(echo "$one" | jq -r '.up')"
  down="$(echo "$one" | jq -r '.down')"
  obfs="$(echo "$one" | jq -r '.obfs')"
  cert_mode="$(echo "$one" | jq -r '.cert_mode')"

  cls
  echo -e "${C_WARN}========== HY2端口重装模式 ==========${C_RST}"
  echo "1) 仅换端口"
  echo "2) 端口+UUID"
  echo "3) 全新安装"
  echo "0) 取消"
  prompt "请选择: " mode
  case "$mode" in
    0) return 0 ;;
    1|2|3) ;;
    *) red "无效"; return 1 ;;
  esac

  local new_port pm
  echo "新端口方式: 1.随机 2.手动指定"
  prompt "选择(默认1): " pm
  [ -z "$pm" ] && pm=1
  case "$pm" in
    2)
      prompt "输入新端口: " new_port
      [[ "$new_port" =~ ^[0-9]+$ ]] || { red "端口无效"; return 1; }
      [ "$new_port" -ge 1 ] && [ "$new_port" -le 65535 ] || { red "端口越界(1-65535)"; return 1; }
      [ "$new_port" -ne "$old_port" ] || { red "新端口不能与旧端口相同"; return 1; }
      if hy2_port_exists_in_conf "$new_port"; then red "端口已被HY2占用"; return 1; fi
      ;;
    *)
      new_port="$(hy2_random_free_port "$old_port")"
      ;;
  esac

  local cert_file key_file cert_mode_in
  if [ "$mode" = "2" ]; then
    auth="$(gen_uuid)"
  elif [ "$mode" = "3" ]; then
    cf_bootstrap_once "HY2"
    prompt "证书模式(1=本机自签 2=CF令牌签发，默认1): " cert_mode_in
    [ -z "${cert_mode_in:-}" ] && cert_mode_in=1
    [[ "$cert_mode_in" =~ ^[12]$ ]] || cert_mode_in=1

    if [ "$cert_mode_in" = "1" ]; then
      prompt "HY2伪装域名(回车默认 ${HY2_SELF_SNI_DEFAULT}): " domain
      [ -z "$domain" ] && domain="$HY2_SELF_SNI_DEFAULT"
      issue_cert_selfsigned "$domain" "$TLS_DIR_HY2" || return 1
      cert_mode="self"
    else
      prompt "HY2域名: " domain; [ -z "$domain" ] && { red "域名不能为空"; return 1; }
      issue_cert_cf "$domain" "" "$TLS_DIR_HY2" || return 1
      cert_mode="cf"
    fi
    prompt "HY2认证AUTH(回车随机UUID): " auth
    [ -z "$auth" ] && auth="$(gen_uuid)"
    prompt "HY2混淆密码OBFS(回车留空=不启用): " obfs
    local prof
    echo "带宽档位: 1.默认(50/250 Mbps) 2.自定义"
    prompt "选择(默认1): " prof
    case "$prof" in
      2)
        prompt "上行Mbps(默认50): " up
        prompt "下行Mbps(默认250): " down
        [ -z "$up" ] && up=50
        [ -z "$down" ] && down=250
        [[ "$up" =~ ^[0-9]+$ ]] || up=50
        [[ "$down" =~ ^[0-9]+$ ]] || down=250
        ;;
      *)
        up=50; down=250 ;;
    esac
  fi

  cert_file="${TLS_DIR_HY2}/${domain}.crt"
  key_file="${TLS_DIR_HY2}/${domain}.key"
  [ -s "$cert_file" ] && [ -s "$key_file" ] || { red "证书文件不存在: $domain"; return 1; }

  local new_tag ib
  new_tag="hy2-${new_port}"
  ib="$(hy2_build_inbound_json "$new_tag" "$new_port" "$auth" "$domain" "$cert_file" "$key_file" "$obfs")"

  update_xray --argjson p "$old_port" 'del(.inbounds[]? | select((.protocol=="hysteria" or .protocol=="hysteria2") and .port==$p))'
  update_xray --argjson ib "$ib" '.inbounds += [$ib]'

  if ! "$XRAY_BIN" run -test -c "$XRAY_CONF" >/tmp/xray_hy2_reinstall_check.log 2>&1; then
    red "Xray 配置校验失败"
    tail -n 80 /tmp/xray_hy2_reinstall_check.log 2>/dev/null || true
    return 1
  fi

  open_port "$new_port" udp || yellow "防火墙自动放行失败，请手动放行 ${new_port}/udp"
  hy2_update_list_entry_by_port "$old_port" "$new_tag" "$new_port" "$domain" "$auth" "$up" "$down" "$obfs" "$cert_mode"
  svc restart xray
  green "重装成功：${old_port} -> ${new_port}"
}

show_hy2_links_only(){
  cls
  init_hy2_list
  [ "$IP_CHECKED" = "1" ] || load_ip_cache >/dev/null 2>&1 || true
  [ "$IP_CHECKED" = "1" ] || check_ip || true
  local ip
  ip="$(pick_node_host)"
  [ -z "$ip" ] && ip=""
  [ -z "$BASE_FULL" ] && BASE_FULL="Node"

  local cnt; cnt="$(jq 'length' "$HY2_LIST" 2>/dev/null || echo 0)"
  [ "${cnt:-0}" -gt 0 ] || { red "暂无HY2实例"; return; }

  green "=============== HY2链接 ================"
  local list
  list="$(jq -c '.[]' "$HY2_LIST")"
  while IFS= read -r one; do
    [ -z "$one" ] && continue
    local p d a up down ob cm insec hn hy_host obf
    p="$(echo "$one" | jq -r '.port')"
    d="$(echo "$one" | jq -r '.domain')"
    a="$(echo "$one" | jq -r '.auth')"
    up="$(echo "$one" | jq -r '.up')"
    down="$(echo "$one" | jq -r '.down')"
    ob="$(echo "$one" | jq -r '.obfs')"
    cm="$(echo "$one" | jq -r '.cert_mode')"
    [[ "$up" =~ ^[0-9]+$ ]] || up=50
    [[ "$down" =~ ^[0-9]+$ ]] || down=250
    insec="0"; [ "$cm" = "self" ] && insec="1"
    hn="${BASE_FULL} - HY2"
    hy_host="$ip"; [ -z "$hy_host" ] && hy_host="$d"
    if [ -n "$ob" ]; then
      obf="&obfs=salamander&obfs-password=${ob}"
    else
      obf=""
    fi
    purple "hysteria2://${a}@${hy_host}:${p}?sni=${d}&insecure=${insec}${obf}&up=${up}&down=${down}#$(url_encode "$hn")"; echo
  done <<< "$list"
  echo "========================================"
}

manage_hy2(){
  install_xray >/dev/null 2>&1 || true
  ensure_dns_rule >/dev/null 2>&1 || true
  init_hy2_list

  while true; do
    cls
    echo -e "${C_WARN}=============== HY2管理 ===============${C_RST}"
    hy2_list_show_table

    menu_item_auto "1" "添加HY2实例"
    menu_item_auto "2" "修改HY2实例"
    menu_item_auto "3" "删除HY2实例"
    menu_item_auto "4" "重装随机端口"
    menu_item_auto "5" "查看HY2链接"
    menu_item_auto "0" "返回"
    echo "==============================================================="
    prompt "请选择: " c
    case "$c" in
      1) configure_hy2_add; pause ;;
      2) configure_hy2_edit; pause ;;
      3) configure_hy2_delete; pause ;;
      4) configure_hy2_reinstall_port; pause ;;
      5) show_hy2_links_only; pause ;;
      0) return ;;
      *) red "无效"; pause ;;
    esac
  done
}

uninstall_hy2_all(){
  [ -f "$XRAY_CONF" ] || { red "xray未安装"; return 1; }
  update_xray 'del(.inbounds[]? | select(.protocol=="hysteria" or .protocol=="hysteria2" or (.tag|tostring|startswith("hy2-"))))'
  rm -f "$HY2_LIST"
  svc restart xray
  green "HY2 全部实例已卸载"
}

# ========== Reality ==========
init_reality_list(){
  mkdir -p "$WORK"
  [ -f "$REALITY_LIST" ] || echo '[]' > "$REALITY_LIST"
}
reality_add_list_entry(){
  local tag="$1" type="$2" port="$3" uuid="$4" priv="$5" pub="$6" sni="$7" target="$8" sid="$9" path="${10}"
  init_reality_list
  jq --arg tag "$tag" --arg type "$type" --argjson port "$port" \
     --arg uuid "$uuid" --arg priv "$priv" --arg pub "$pub" \
     --arg sni "$sni" --arg target "$target" --arg sid "$sid" --arg path "$path" \
     '. += [{"tag":$tag,"type":$type,"port":$port,"uuid":$uuid,"privateKey":$priv,"publicKey":$pub,"serverName":$sni,"target":$target,"shortId":$sid,"path":$path}]' \
     "$REALITY_LIST" > "${REALITY_LIST}.tmp" && mv "${REALITY_LIST}.tmp" "$REALITY_LIST"
}
reality_del_by_port(){
  local p="$1"
  update_xray --argjson p "$p" 'del(.inbounds[]? | select(.port==$p and .protocol=="vless" and .streamSettings.security=="reality"))'
  init_reality_list
  jq --argjson p "$p" 'map(select(.port != $p))' "$REALITY_LIST" > "${REALITY_LIST}.tmp" && mv "${REALITY_LIST}.tmp" "$REALITY_LIST"
}
reality_list_show_table(){
  init_reality_list
  local list
  list="$(jq -c '.[]' "$REALITY_LIST" 2>/dev/null || true)"
  if [ -z "$list" ]; then
    echo -e "当前: ${C_BAD}未配置${C_RST}"
    return
  fi
  echo "---------------------------------------------------------------"
  echo " 序号 | 类型      | 端口   | SNI"
  echo "---------------------------------------------------------------"
  local i=1
  while IFS= read -r one; do
    [ -z "$one" ] && continue
    printf " %-4s| %-9s| %-6s| %s\n" \
      "$i" \
      "$(echo "$one" | jq -r '.type')" \
      "$(echo "$one" | jq -r '.port')" \
      "$(echo "$one" | jq -r '.serverName')"
    i=$((i+1))
  done <<< "$list"
}
reality_pick_by_index(){
  local idx="$1"
  init_reality_list
  jq -c ".[$((idx-1))] // empty" "$REALITY_LIST" 2>/dev/null || true
}

configure_reality_xhttp_add(){
  install_xray || return 1
  ensure_dns_rule || return 1
  init_reality_list
  cf_bootstrap_once "Reality"

  local port uuid sni target sid path kp priv pub tag ib
  prompt "XHTTP-Reality端口: " port
  if [ -z "$port" ]; then
    port="$(random_free_port)"
  else
    [[ "$port" =~ ^[0-9]+$ ]] || { red "端口无效"; return 1; }
    [ "$port" -ge 1 ] && [ "$port" -le 65535 ] || { red "端口越界(1-65535)"; return 1; }
    port_exists_in_conf "$port" && { red "端口已存在"; return 1; }
  fi

  prompt "UUID(留空随机): " uuid; [ -z "$uuid" ] && uuid="$(gen_uuid)"
  prompt "serverName(SNI，例如 www.yahoo.com): " sni; [ -z "$sni" ] && { red "不能为空"; return 1; }
  prompt "target(例如 ${sni}:443，默认 ${sni}:443): " target; [ -z "$target" ] && target="${sni}:443"
  prompt "shortId(留空随机8位hex): " sid; [ -z "$sid" ] && sid="$(rand_hex 8)"
  prompt "xhttp path(默认 /r1): " path; [ -z "$path" ] && path="/r1"

  kp="$(xray_x25519_keys)" || { red "生成Reality密钥失败"; return 1; }
  priv="${kp%%|*}"; pub="${kp##*|}"

  tag="vless-reality-xhttp-${port}"
  ib="$(jq -nc \
    --arg tag "$tag" --argjson port "$port" --arg uuid "$uuid" \
    --arg path "$path" --arg target "$target" --arg sni "$sni" \
    --arg priv "$priv" --arg sid "$sid" \
'{
  "tag":$tag,
  "listen":"0.0.0.0",
  "port":$port,
  "protocol":"vless",
  "settings":{"clients":[{"id":$uuid,"flow":""}],"decryption":"none"},
  "streamSettings":{
    "network":"xhttp",
    "security":"reality",
    "xhttpSettings":{"path":$path},
    "realitySettings":{
      "target":$target,
      "serverNames":[$sni],
      "privateKey":$priv,
      "shortIds":[$sid]
    }
  },
  "sniffing":{"enabled":true,"destOverride":["http","tls","quic"]}
}')"

  update_xray --argjson ib "$ib" '.inbounds += [$ib]'

  if ! "$XRAY_BIN" run -test -c "$XRAY_CONF" >/tmp/xray_reality_xhttp_check.log 2>&1; then
    red "配置校验失败"
    tail -n 80 /tmp/xray_reality_xhttp_check.log 2>/dev/null || true
    update_xray --argjson p "$port" 'del(.inbounds[]? | select(.port==$p and .streamSettings.security=="reality"))'
    return 1
  fi

  open_port "$port" tcp || yellow "请手动放行 ${port}/tcp"
  reality_add_list_entry "$tag" "xhttp" "$port" "$uuid" "$priv" "$pub" "$sni" "$target" "$sid" "$path"
  svc restart xray
  green "VLESS-XHTTP-Reality 已添加（端口 ${port}）"
}

configure_reality_vision_add(){
  install_xray || return 1
  ensure_dns_rule || return 1
  init_reality_list
  cf_bootstrap_once "Reality"

  local port uuid sni target sid kp priv pub tag ib
  prompt "Vision-Reality端口: " port
  if [ -z "$port" ]; then
    port="$(random_free_port)"
  else
    [[ "$port" =~ ^[0-9]+$ ]] || { red "端口无效"; return 1; }
    [ "$port" -ge 1 ] && [ "$port" -le 65535 ] || { red "端口越界(1-65535)"; return 1; }
    port_exists_in_conf "$port" && { red "端口已存在"; return 1; }
  fi

  prompt "UUID(留空随机): " uuid; [ -z "$uuid" ] && uuid="$(gen_uuid)"
  prompt "serverName(SNI，例如 www.yahoo.com): " sni; [ -z "$sni" ] && { red "不能为空"; return 1; }
  prompt "target(默认 ${sni}:443): " target; [ -z "$target" ] && target="${sni}:443"
  prompt "shortId(留空随机16位hex): " sid; [ -z "$sid" ] && sid="$(rand_hex 16)"

  kp="$(xray_x25519_keys)" || { red "生成Reality密钥失败"; return 1; }
  priv="${kp%%|*}"; pub="${kp##*|}"

  tag="vless-reality-vision-${port}"
  ib="$(jq -nc \
    --arg tag "$tag" --argjson port "$port" --arg uuid "$uuid" \
    --arg target "$target" --arg sni "$sni" --arg priv "$priv" --arg sid "$sid" \
'{
  "tag":$tag,
  "listen":"0.0.0.0",
  "port":$port,
  "protocol":"vless",
  "settings":{"clients":[{"id":$uuid,"flow":"xtls-rprx-vision"}],"decryption":"none"},
  "streamSettings":{
    "network":"raw",
    "security":"reality",
    "realitySettings":{
      "target":$target,
      "serverNames":[$sni],
      "privateKey":$priv,
      "shortIds":[$sid]
    }
  },
  "sniffing":{"enabled":true,"destOverride":["http","tls","quic"],"routeOnly":true}
}')"

  update_xray --argjson ib "$ib" '.inbounds += [$ib]'

  if ! "$XRAY_BIN" run -test -c "$XRAY_CONF" >/tmp/xray_reality_vision_check.log 2>&1; then
    red "配置校验失败"
    tail -n 80 /tmp/xray_reality_vision_check.log 2>/dev/null || true
    update_xray --argjson p "$port" 'del(.inbounds[]? | select(.port==$p and .streamSettings.security=="reality"))'
    return 1
  fi

  open_port "$port" tcp || yellow "请手动放行 ${port}/tcp"
  reality_add_list_entry "$tag" "vision" "$port" "$uuid" "$priv" "$pub" "$sni" "$target" "$sid" ""
  svc restart xray
  green "VLESS-TCP-XTLS-Vision-REALITY 已添加（端口 ${port}）"
}

configure_reality_delete(){
  init_reality_list
  local cnt; cnt="$(jq 'length' "$REALITY_LIST" 2>/dev/null || echo 0)"
  [ "${cnt:-0}" -gt 0 ] || { red "无可删除实例"; return 1; }
  reality_list_show_table
  local idx one p
  prompt "选择序号删除(0取消): " idx
  [[ "$idx" =~ ^[0-9]+$ ]] || { red "输入无效"; return 1; }
  [ "$idx" -eq 0 ] && return 0
  [ "$idx" -ge 1 ] && [ "$idx" -le "$cnt" ] || { red "序号越界"; return 1; }
  one="$(reality_pick_by_index "$idx")"
  p="$(echo "$one" | jq -r '.port')"
  [ -n "$p" ] || { red "读取失败"; return 1; }

  reality_del_by_port "$p"
  if ! "$XRAY_BIN" run -test -c "$XRAY_CONF" >/tmp/xray_reality_del_check.log 2>&1; then
    red "配置校验失败，删除可能未生效"
    tail -n 60 /tmp/xray_reality_del_check.log 2>/dev/null || true
    return 1
  fi
  svc restart xray
  green "已删除 Reality 实例: 端口 $p"
}

show_reality_links_only(){
  cls
  init_reality_list
  [ "$IP_CHECKED" = "1" ] || load_ip_cache >/dev/null 2>&1 || true
  [ "$IP_CHECKED" = "1" ] || check_ip || true
  local ip
  ip="$(pick_node_host)"
  [ -z "$BASE_FULL" ] && BASE_FULL="Node"

  local cnt; cnt="$(jq 'length' "$REALITY_LIST" 2>/dev/null || echo 0)"
  [ "${cnt:-0}" -gt 0 ] || { red "暂无 Reality 实例"; return; }

  green "============= Reality 链接 ============="
  local list
  list="$(jq -c '.[]' "$REALITY_LIST" 2>/dev/null || true)"
  while IFS= read -r one; do
    [ -z "$one" ] && continue
    local t p u pub sni sid path name host
    t="$(echo "$one" | jq -r '.type')"
    p="$(echo "$one" | jq -r '.port')"
    u="$(echo "$one" | jq -r '.uuid')"
    pub="$(echo "$one" | jq -r '.publicKey')"
    sni="$(echo "$one" | jq -r '.serverName')"
    sid="$(echo "$one" | jq -r '.shortId')"
    path="$(echo "$one" | jq -r '.path')"
    host="$ip"; [ -z "$host" ] && host="$sni"

    if [ "$t" = "xhttp" ]; then
      name="${BASE_FULL} - RealityXHTTP"
      purple "vless://${u}@${host}:${p}?encryption=none&security=reality&sni=${sni}&fp=chrome&pbk=${pub}&sid=${sid}&type=xhttp&path=$(url_encode "$path")#$(url_encode "$name")"; echo
    else
      name="${BASE_FULL} - RealityVision"
      purple "vless://${u}@${host}:${p}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${sni}&fp=chrome&pbk=${pub}&sid=${sid}&type=tcp#$(url_encode "$name")"; echo
    fi
  done <<< "$list"
  echo "========================================"
}

manage_reality(){
  install_xray >/dev/null 2>&1 || true
  ensure_dns_rule >/dev/null 2>&1 || true
  init_reality_list

  while true; do
    cls
    echo -e "${C_WARN}============= Reality管理 =============${C_RST}"
    reality_list_show_table
    menu_item_auto "1" "添加VLESS-XHTTP-Reality"
    menu_item_auto "2" "添加VLESS-TCP-XTLS-Vision-REALITY"
    menu_item_auto "3" "删除Reality实例"
    menu_item_auto "4" "查看Reality链接"
    menu_item_auto "0" "返回"
    echo "======================================="
    prompt "请选择: " c
    case "$c" in
      1) configure_reality_xhttp_add; pause ;;
      2) configure_reality_vision_add; pause ;;
      3) configure_reality_delete; pause ;;
      4) show_reality_links_only; pause ;;
      0) return ;;
      *) red "无效"; pause ;;
    esac
  done
}
# ========== Nodes ==========
get_xhttp_mode_from_conf(){
  local p="$1" mode
  [ -f "$XRAY_CONF" ] || { echo "${XHTTP_MODE:-auto}"; return; }

  mode="$(jq -r --argjson p "$p" '
    first(.inbounds[]?
      | select(.protocol=="vless" and .port==$p)
      | (.streamSettings.xhttpSettings.mode // empty)
    ) // empty
  ' "$XRAY_CONF" 2>/dev/null || true)"

  [ -n "$mode" ] || mode="${XHTTP_MODE:-auto}"
  echo "$mode"
}

get_xhttp_extra_param_from_conf(){
  local p="$1" extra
  [ -f "$XRAY_CONF" ] || return 0

  extra="$(jq -c --argjson p "$p" '
    first(.inbounds[]?
      | select(.protocol=="vless" and .port==$p)
      | (.streamSettings.xhttpSettings.extra // empty)
    ) // empty
  ' "$XRAY_CONF" 2>/dev/null || true)"

  [ -n "$extra" ] && [ "$extra" != "null" ] || return 0
  printf '&extra=%s' "$(url_encode "$extra")"
}

show_xray_nodes(){
  cls
  [ "$IP_CHECKED" = "1" ] || load_ip_cache >/dev/null 2>&1 || true
  [ "$IP_CHECKED" = "1" ] || check_ip || true
  [ -f "$XRAY_CONF" ] || { red "xray未安装"; return; }
  load_cf_mode

  local ip="" uuid cnt=0
  ip="$(pick_node_host)"; uuid="$(xray_uuid)"; [ -z "$BASE_FULL" ] && BASE_FULL="Node"

  green "=============== 节点链接 ================"

  if [ "$CF_MODE" = "argo" ] && [ -f "$ARGO_DOMAIN" ]; then
    local d xmode xextra_param nx nw ns
    d="$(cat "$ARGO_DOMAIN")"
    xmode="$(get_xhttp_mode_from_conf 8082)"
    xextra_param="$(get_xhttp_extra_param_from_conf 8082)"
    nx="${BASE_FULL} - ArgoXHTTP"; nw="${BASE_FULL} - ArgoWS"; ns="${BASE_FULL} - ArgoSS"
    purple "vless://${uuid}@${CFIP}:443?encryption=none&security=tls&sni=${d}&alpn=h2&fp=chrome&type=xhttp&host=${d}&path=%2Fxgo&mode=${xmode}${xextra_param}#$(url_encode "$nx")"; echo
    purple "vless://${uuid}@${CFIP}:443?encryption=none&security=tls&sni=${d}&fp=chrome&type=ws&host=${d}&path=%2Fargo%3Fed%3D2560#$(url_encode "$nw")"; echo
    cnt=$((cnt+2))
    local ssib
    ssib="$(jq -c '.inbounds[]? | select(.protocol=="shadowsocks" and .port==8083)' "$XRAY_CONF" 2>/dev/null || true)"
    if [ -n "$ssib" ]; then
      local m pw b64
      m="$(echo "$ssib" | jq -r '.settings.method')"; pw="$(echo "$ssib" | jq -r '.settings.password')"
      b64="$(echo -n "${m}:${pw}" | base64 | tr -d '\n')"
      local ss_plugin
      ss_plugin="$(url_encode "v2ray-plugin;mode=websocket;host=${d};path=/ssgo;mux=0")"
      purple "ss://${b64}@${SS_FIXED_IP}:2052?plugin=${ss_plugin}#$(url_encode "$ns")"; echo
      cnt=$((cnt+1))
    fi
  fi

  if [ "$CF_MODE" = "origin" ] && [ -f "$ARGO_DOMAIN" ]; then
    local d xmode xextra_param nx nw ns
    d="$(cat "$ARGO_DOMAIN")"
    xmode="$(get_xhttp_mode_from_conf "$ORIGIN_VLESS_XHTTP_PORT")"
    xextra_param="$(get_xhttp_extra_param_from_conf "$ORIGIN_VLESS_XHTTP_PORT")"
    nx="${BASE_FULL} - CFOriginXHTTP"; nw="${BASE_FULL} - CFOriginWS"; ns="${BASE_FULL} - CFOriginSS"
    purple "vless://${uuid}@${CFIP}:443?encryption=none&security=tls&sni=${d}&alpn=h2&fp=chrome&type=xhttp&host=${d}&path=%2Fxgo&mode=${xmode}${xextra_param}#$(url_encode "$nx")"; echo
    purple "vless://${uuid}@${CFIP}:443?encryption=none&security=tls&sni=${d}&fp=chrome&type=ws&host=${d}&path=%2Fargo%3Fed%3D2560#$(url_encode "$nw")"; echo
    cnt=$((cnt+2))
    local ssib
    ssib="$(jq -c --argjson p "$ORIGIN_SS_WS_PORT" '.inbounds[]? | select(.protocol=="shadowsocks" and .port==$p)' "$XRAY_CONF" 2>/dev/null || true)"
    if [ -n "$ssib" ]; then
      local m pw b64
      m="$(echo "$ssib" | jq -r '.settings.method')"; pw="$(echo "$ssib" | jq -r '.settings.password')"
      b64="$(echo -n "${m}:${pw}" | base64 | tr -d '\n')"
      local ss_plugin
      ss_plugin="$(url_encode "v2ray-plugin;mode=websocket;host=${d};path=/ssgo;mux=0")"
      purple "ss://${b64}@${SS_FIXED_IP}:2052?plugin=${ss_plugin}#$(url_encode "$ns")"; echo
      cnt=$((cnt+1))
    fi
  fi

  local sl
  sl="$(jq -c '.inbounds[]? | select(.protocol=="socks")' "$XRAY_CONF" 2>/dev/null || true)"
  if [ -n "$sl" ] && [ -n "$ip" ]; then
    while read -r line; do
      [ -z "$line" ] && continue
      local p u pw n
      p="$(echo "$line" | jq -r '.port')"; u="$(echo "$line" | jq -r '.settings.accounts[0].user')"; pw="$(echo "$line" | jq -r '.settings.accounts[0].pass')"
      n="${BASE_FULL} - Socks5"
      purple "socks5://${u}:${pw}@${ip}:${p}#$(url_encode "$n")"; echo
      cnt=$((cnt+1))
    done <<< "$sl"
  fi

  init_hy2_list
  if [ -f "$HY2_LIST" ] && [ "$(jq 'length' "$HY2_LIST" 2>/dev/null || echo 0)" -gt 0 ]; then
    local list
    list="$(jq -c '.[]' "$HY2_LIST" 2>/dev/null || true)"
    while IFS= read -r one; do
      [ -z "$one" ] && continue
      local p d a up down ob cm insec hn hy_host obf
      p="$(echo "$one" | jq -r '.port')"
      d="$(echo "$one" | jq -r '.domain')"
      a="$(echo "$one" | jq -r '.auth')"
      up="$(echo "$one" | jq -r '.up')"
      down="$(echo "$one" | jq -r '.down')"
      ob="$(echo "$one" | jq -r '.obfs')"
      cm="$(echo "$one" | jq -r '.cert_mode')"
      [[ "$up" =~ ^[0-9]+$ ]] || up=50
      [[ "$down" =~ ^[0-9]+$ ]] || down=250
      insec="0"; [ "$cm" = "self" ] && insec="1"
      hn="${BASE_FULL} - HY2"
      hy_host="$ip"; [ -z "$hy_host" ] && hy_host="$d"
      if [ -n "$ob" ]; then
        obf="&obfs=salamander&obfs-password=${ob}"
      else
        obf=""
      fi
      purple "hysteria2://${a}@${hy_host}:${p}?sni=${d}&insecure=${insec}${obf}&up=${up}&down=${down}#$(url_encode "$hn")"; echo
      cnt=$((cnt+1))
    done <<< "$list"
  fi

  init_reality_list
  if [ -f "$REALITY_LIST" ] && [ "$(jq 'length' "$REALITY_LIST" 2>/dev/null || echo 0)" -gt 0 ]; then
    local rlist
    rlist="$(jq -c '.[]' "$REALITY_LIST" 2>/dev/null || true)"
    while IFS= read -r one; do
      [ -z "$one" ] && continue
      local t p u pub sni sid path name host
      t="$(echo "$one" | jq -r '.type')"
      p="$(echo "$one" | jq -r '.port')"
      u="$(echo "$one" | jq -r '.uuid')"
      pub="$(echo "$one" | jq -r '.publicKey')"
      sni="$(echo "$one" | jq -r '.serverName')"
      sid="$(echo "$one" | jq -r '.shortId')"
      path="$(echo "$one" | jq -r '.path')"
      host="$ip"; [ -z "$host" ] && host="$sni"

      if [ "$t" = "xhttp" ]; then
        name="${BASE_FULL} - RealityXHTTP"
        purple "vless://${u}@${host}:${p}?encryption=none&security=reality&sni=${sni}&fp=chrome&pbk=${pub}&sid=${sid}&type=xhttp&path=$(url_encode "$path")#$(url_encode "$name")"; echo
      else
        name="${BASE_FULL} - RealityVision"
        purple "vless://${u}@${host}:${p}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${sni}&fp=chrome&pbk=${pub}&sid=${sid}&type=tcp#$(url_encode "$name")"; echo
      fi
      cnt=$((cnt+1))
    done <<< "$rlist"
  fi

  [ "$cnt" -eq 0 ] && yellow "暂无配置节点"
  echo "=========================================="
}

# ========== Socks5 ==========
manage_socks5(){
  if [ ! -f "$XRAY_CONF" ]; then
    cls
    red "未检测到 Xray"
    menu_item_auto "1" "安装Xray"
    menu_item_auto "0" "返回"
    prompt "请选择: " k
    case "$k" in
      1) install_xray || { red "安装失败"; pause; return; } ;;
      0) return ;;
      *) return ;;
    esac
  fi

  ensure_dns_rule || { red "初始化失败"; pause; return; }

  while true; do
    cls
    local list
    list="$(jq -c '.inbounds[]? | select(.protocol=="socks")' "$XRAY_CONF" 2>/dev/null || true)"

    echo -e "${C_WARN}=============== Socks5管理 ===============${C_RST}"
    if [ -z "$list" ]; then
      echo -e "当前: ${C_BAD}未配置${C_RST}"
    else
      echo "-----------------------------------------------"
      echo "  序号 | 端口    | 用户名      | 密码"
      echo "-----------------------------------------------"
      local i=1
      while IFS= read -r line; do
        [ -z "$line" ] && continue
        local p u pw
        p="$(echo "$line" | jq -r '.port // empty')"
        u="$(echo "$line" | jq -r '.settings.accounts[0].user // empty')"
        pw="$(echo "$line" | jq -r '.settings.accounts[0].pass // empty')"
        printf "  %-4s| %-8s| %-12s| %s\n" "$i" "$p" "$u" "$pw"
        i=$((i+1))
      done <<< "$list"
    fi

    echo "-----------------------------------------------"
    menu_item_auto "1" "安装Socks5"
    menu_item_auto "2" "修改Socks5"
    menu_item_auto "3" "卸载Socks5"
    menu_item_auto "0" "返回"
    echo "==============================================="
    prompt "请选择: " c

    case "$c" in
      1)
        local p u pw ex
        prompt "端口: " p
        prompt "用户名: " u
        prompt "密码: " pw

        if ! [[ "$p" =~ ^[0-9]+$ ]] || [ "$p" -lt 1 ] || [ "$p" -gt 65535 ] || [ -z "$u" ] || [ -z "$pw" ]; then
          red "输入无效"
          pause
          continue
        fi
        ex="$(jq --argjson p "$p" '[.inbounds[]? | select(.port==$p)] | length' "$XRAY_CONF" 2>/dev/null || echo 0)"
        if [ "${ex:-0}" -gt 0 ]; then
          red "端口已存在于Xray配置"
          pause
          continue
        fi

        update_xray --argjson p "$p" --arg u "$u" --arg pw "$pw" \
          '.inbounds += [{
            "tag":("socks-"+($p|tostring)),
            "port":$p,
            "listen":"0.0.0.0",
            "protocol":"socks",
            "settings":{"auth":"password","accounts":[{"user":$u,"pass":$pw}],"udp":true},
            "sniffing":{"enabled":true,"destOverride":["http","tls"],"metadataOnly":false}
          }]'

        if ! "$XRAY_BIN" run -test -c "$XRAY_CONF" >/tmp/xray_socks_add_check.log 2>&1; then
          red "配置校验失败，新增未生效"
          tail -n 50 /tmp/xray_socks_add_check.log 2>/dev/null || true
          pause
          continue
        fi

        svc restart xray
        green "添加成功"
        pause
        ;;

      2)
        if [ -z "$list" ]; then
          red "当前无可修改的Socks5配置"
          pause
          continue
        fi

        local -a rows=()
        mapfile -t rows < <(printf '%s\n' "$list" | sed '/^$/d')

        local idx
        prompt "请输入要修改的序号(0取消): " idx
        if ! [[ "$idx" =~ ^[0-9]+$ ]]; then
          red "输入无效"
          pause
          continue
        fi
        [ "$idx" -eq 0 ] && continue
        if [ "$idx" -lt 1 ] || [ "$idx" -gt "${#rows[@]}" ]; then
          red "序号越界"
          pause
          continue
        fi

        local selected_line port user pass
        selected_line="${rows[$((idx-1))]}"
        port="$(echo "$selected_line" | jq -r '.port')"
        user="$(echo "$selected_line" | jq -r '.settings.accounts[0].user')"
        pass="$(echo "$selected_line" | jq -r '.settings.accounts[0].pass')"

        green "当前配置 - 端口: $port, 用户名: $user"
        local new_user new_pass
        prompt "新用户名(留空保持不变): " new_user
        prompt "新密码(留空保持不变): " new_pass
        [ -z "$new_user" ] && new_user="$user"
        [ -z "$new_pass" ] && new_pass="$pass"

        update_xray --argjson p "$port" --arg u "$new_user" --arg pw "$new_pass" \
          '(.inbounds[]? | select(.protocol=="socks" and .port==$p) | .settings.accounts[0]) |= {"user":$u,"pass":$pw}'

        if ! "$XRAY_BIN" run -test -c "$XRAY_CONF" >/tmp/xray_socks_mod_check.log 2>&1; then
          red "配置校验失败，修改未生效"
          tail -n 50 /tmp/xray_socks_mod_check.log 2>/dev/null || true
          pause
          continue
        fi

        svc restart xray
        green "修改成功"
        pause
        ;;

      3)
        if [ -z "$list" ]; then
          red "无可删项"
          pause
          continue
        fi

        local -a rows=() ports=()
        mapfile -t rows < <(printf '%s\n' "$list" | sed '/^$/d')

        local i=1
        for line in "${rows[@]}"; do
          local p u
          p="$(echo "$line" | jq -r '.port')"
          u="$(echo "$line" | jq -r '.settings.accounts[0].user')"
          echo "  ${i}. 端口 ${p} | 用户 ${u}"
          ports[$i]="$p"
          i=$((i+1))
        done
        echo "  0. 取消"

        local del_idx
        prompt "序号: " del_idx
        if ! [[ "$del_idx" =~ ^[0-9]+$ ]]; then
          red "输入无效"
          pause
          continue
        fi
        [ "$del_idx" -eq 0 ] && continue
        if [ "$del_idx" -lt 1 ] || [ "$del_idx" -ge "$i" ]; then
          red "序号越界"
          pause
          continue
        fi

        update_xray --argjson p "${ports[$del_idx]}" \
          'del(.inbounds[]? | select(.protocol=="socks" and .port==$p))'

        if ! "$XRAY_BIN" run -test -c "$XRAY_CONF" >/tmp/xray_socks_del_check.log 2>&1; then
          red "配置校验失败，删除未生效"
          tail -n 50 /tmp/xray_socks_del_check.log 2>/dev/null || true
          pause
          continue
        fi

        svc restart xray
        green "已删除"
        pause
        ;;

      0) return ;;
      *) red "无效"; pause ;;
    esac
  done
}

# ========== Live logs ==========
foreground_xray_log(){
  [ -x "$XRAY_BIN" ] || { red "xray 未安装"; pause; return 1; }
  [ -f "$XRAY_CONF" ] || { red "缺少配置: $XRAY_CONF"; pause; return 1; }
  local bak="${XRAY_CONF}.bak.fg.$(date +%s)"
  cp -a "$XRAY_CONF" "$bak"
  if ! jq '.log=(.log//{})|.log.access=""|.log.error=""|.log.loglevel="debug"|.log.dnsLog=true' "$XRAY_CONF" > "${XRAY_CONF}.tmp"; then
    red "写入 Xray 日志配置失败"; rm -f "${XRAY_CONF}.tmp" "$bak"; pause; return 1
  fi
  mv "${XRAY_CONF}.tmp" "$XRAY_CONF"
  if ! "$XRAY_BIN" run -test -c "$XRAY_CONF" >/tmp/xray_check_fg.log 2>&1; then
    red "Xray 配置校验失败，无法前台运行"; cp -f "$bak" "$XRAY_CONF"; rm -f "$bak"
    tail -n 80 /tmp/xray_check_fg.log 2>/dev/null || true; pause; return 1
  fi
  yellow "即将停止 xray 后台服务并前台输出日志..."
  svc stop xray || true; pkill -f "^${XRAY_BIN} run -c ${XRAY_CONF}$" >/dev/null 2>&1 || true; pkill -x xray >/dev/null 2>&1 || true; sleep 1
  green "前台日志已启动（Ctrl+C 退出）"; echo "日志文件: /tmp/xray-live.log"
  local old_int_trap; old_int_trap="$(trap -p INT || true)"; trap ':' INT
  set +e; "$XRAY_BIN" run -c "$XRAY_CONF" 2>&1 | tee /tmp/xray-live.log; set -e
  if [ -n "$old_int_trap" ]; then eval "$old_int_trap"; else trap - INT; fi
  cp -f "$bak" "$XRAY_CONF"; rm -f "$bak"
  yellow "已退出前台日志，正在恢复后台服务..."
  svc start xray || true; sleep 1; is_running xray && green "xray 已恢复后台运行" || red "xray 恢复失败，请手动检查"; pause
}

# ========== Service Monitor ==========
setup_service_monitor(){
  local svcname="tunnel-argo"
  if ! service_exists "$svcname"; then
    red "服务 $svcname 未安装"; return 1
  fi
  yellow "开始设置服务监控（$svcname），每10分钟进行连通性检测"

  local monitor_script="${WORK}/monitor_argo.sh"
  local monitor_pid_file="${WORK}/monitor_argo.pid"
  local ready_url="http://127.0.0.1:2000/ready"
  local metrics_url="http://127.0.0.1:2000/metrics"

  if [ -f "$monitor_pid_file" ]; then
    local old_pid; old_pid="$(cat "$monitor_pid_file" 2>/dev/null || true)"
    if [ -n "$old_pid" ] && kill -0 "$old_pid" 2>/dev/null; then
      green "监控进程已在运行 (PID: $old_pid)"; return 0
    else
      rm -f "$monitor_pid_file"
    fi
  fi

  mkdir -p "$WORK"
  [ -f "$MONITOR_DOWN_COUNT" ] || echo 0 > "$MONITOR_DOWN_COUNT"

  cat > "$monitor_script" <<'MONITOR_SCRIPT'
#!/usr/bin/env bash
set -euo pipefail

SVCNAME="tunnel-argo"
WORK="/etc/xray"
LOG="${WORK}/monitor_argo.log"
DOWN_COUNT_FILE="${WORK}/monitor_argo_down.count"

CHECK_INTERVAL=600
RETRY_INTERVAL=20
MAX_RETRIES=3
RESTART_DELAY=60
WAIT_AFTER_FAILURE=600

READY_URL="http://127.0.0.1:2000/ready"
METRICS_URL="http://127.0.0.1:2000/metrics"

[ -f "$DOWN_COUNT_FILE" ] || echo 0 > "$DOWN_COUNT_FILE"

inc_down_count() {
  local c=0
  c="$(cat "$DOWN_COUNT_FILE" 2>/dev/null || echo 0)"
  [[ "$c" =~ ^[0-9]+$ ]] || c=0
  c=$((c+1))
  echo "$c" > "$DOWN_COUNT_FILE"
}

http_ok() {
  local url="$1"
  if command -v curl >/dev/null 2>&1; then
    curl -fsS --max-time 4 "$url" >/dev/null 2>&1
    return $?
  elif command -v wget >/dev/null 2>&1; then
    wget -q -T 4 -O /dev/null "$url" >/dev/null 2>&1
    return $?
  else
    return 1
  fi
}

metrics_valid() {
  local body=""
  if command -v curl >/dev/null 2>&1; then
    body="$(curl -fsS --max-time 4 "$METRICS_URL" 2>/dev/null || true)"
  elif command -v wget >/dev/null 2>&1; then
    body="$(wget -q -T 4 -O - "$METRICS_URL" 2>/dev/null || true)"
  fi
  [ -n "$body" ] && echo "$body" | grep -qE '(^# HELP|cloudflared_)'
}

health_check() {
  if http_ok "$READY_URL"; then
    return 0
  fi
  metrics_valid
}

restart_svc() {
  if [ -f /etc/alpine-release ] && command -v rc-service >/dev/null 2>&1; then
    rc-service "$SVCNAME" restart >/dev/null 2>&1 || true
  else
    systemctl restart "$SVCNAME" >/dev/null 2>&1 || true
  fi
}

is_running_svc() {
  if [ -f /etc/alpine-release ] && command -v rc-service >/dev/null 2>&1; then
    rc-service "$SVCNAME" status 2>/dev/null | grep -q started
  else
    [ "$(systemctl is-active "$SVCNAME" 2>/dev/null)" = "active" ]
  fi
}

echo "[$(date '+%F %T')] 监控启动: $SVCNAME" >> "$LOG"

while true; do
  check_failed=0
  for ((i=1; i<=MAX_RETRIES; i++)); do
    if health_check; then
      echo "[$(date '+%F %T')] 健康检查通过 (第${i}次，ready/metrics)" >> "$LOG"
      check_failed=0
      break
    else
      echo "[$(date '+%F %T')] 健康检查失败 (第${i}次，ready/metrics)" >> "$LOG"
      check_failed=1
      [ "$i" -lt "$MAX_RETRIES" ] && sleep "$RETRY_INTERVAL"
    fi
  done

  if [ "$check_failed" -eq 1 ]; then
    inc_down_count
    echo "[$(date '+%F %T')] 掉线计数 +1，当前: $(cat "$DOWN_COUNT_FILE" 2>/dev/null || echo 0)" >> "$LOG"
    echo "[$(date '+%F %T')] 连续${MAX_RETRIES}次失败，重启服务..." >> "$LOG"
    restart_svc
    sleep "$RESTART_DELAY"

    if is_running_svc; then
      echo "[$(date '+%F %T')] 重启后服务运行中" >> "$LOG"
    else
      echo "[$(date '+%F %T')] 重启后仍未运行，等待${WAIT_AFTER_FAILURE}秒后再试" >> "$LOG"
      sleep "$WAIT_AFTER_FAILURE"
      restart_svc
      sleep 10
      if is_running_svc; then
        echo "[$(date '+%F %T')] 二次重启成功" >> "$LOG"
      else
        echo "[$(date '+%F %T')] 二次重启仍失败，等待下一轮" >> "$LOG"
      fi
    fi
  fi

  sleep "$CHECK_INTERVAL"
done
MONITOR_SCRIPT

  chmod +x "$monitor_script"
  nohup "$monitor_script" >/dev/null 2>&1 &
  echo $! > "$monitor_pid_file"

  green "服务监控已设置，监控日志: ${WORK}/monitor_argo.log"
  green "监控进程 PID: $(cat "$monitor_pid_file")"
  green "健康检查: ${ready_url} (失败则回退 ${metrics_url})"
}

stop_service_monitor(){
  local monitor_pid_file="${WORK}/monitor_argo.pid"
  if [ -f "$monitor_pid_file" ]; then
    local pid; pid="$(cat "$monitor_pid_file" 2>/dev/null || true)"
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
      kill "$pid" 2>/dev/null || true
      rm -f "$monitor_pid_file"
      green "服务监控已停止"
    else
      rm -f "$monitor_pid_file"
      yellow "监控进程未运行"
    fi
  else
    yellow "未设置服务监控"
  fi
}

view_service_monitor_log(){
  cls
  echo -e "${C_WARN}=========== 服务监控日志 ===========${C_RST}"
  if [ -f "$MONITOR_LOG" ]; then
    tail -n 120 "$MONITOR_LOG"
  else
    yellow "暂无日志: $MONITOR_LOG"
  fi
  echo "-------------------------------------"
  local c
  c="$(cat "$MONITOR_DOWN_COUNT" 2>/dev/null || echo 0)"
  [[ "$c" =~ ^[0-9]+$ ]] || c=0
  green "累计掉线次数: $c"
}

manage_service_monitor(){
  while true; do
    cls
    local running="未运行" pid=""
    if [ -f "${WORK}/monitor_argo.pid" ]; then
      pid="$(cat "${WORK}/monitor_argo.pid" 2>/dev/null || true)"
      if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
        running="运行中(PID: $pid)"
      fi
    fi
    local c
    c="$(cat "$MONITOR_DOWN_COUNT" 2>/dev/null || echo 0)"
    [[ "$c" =~ ^[0-9]+$ ]] || c=0

    echo -e "${C_WARN}=========== 服务监控管理 ===========${C_RST}"
    echo -e "状态: \033[1;36m${running}\033[0m"
    echo -e "累计掉线: \033[1;36m${c}\033[0m"
    echo "-------------------------------------"
    menu_item_auto "1" "启动监控"
    menu_item_auto "2" "停止监控"
    menu_item_auto "3" "查看日志"
    menu_item_auto "0" "返回"
    echo "====================================="
    prompt "请选择: " x
    case "$x" in
      1) setup_service_monitor; pause ;;
      2) stop_service_monitor; pause ;;
      3) view_service_monitor_log; pause ;;
      0) return ;;
      *) red "无效"; pause ;;
    esac
  done
}

# ========== SWAP ==========
swap_cleanup_fstab(){ [ -f /etc/fstab ] && sed -i '/^\/swapfile[[:space:]]/d' /etc/fstab; }
swap_disable_all(){
  awk 'NR>1{print $1}' /proc/swaps 2>/dev/null | while read -r d; do [ -n "$d" ] && swapoff "$d" >/dev/null 2>&1 || true; done
  [ -f /swapfile ] && rm -f /swapfile
  swap_cleanup_fstab
  if [ -d /sys/class/zram-control ] || [ -e /dev/zram0 ]; then
    for z in /sys/block/zram*; do
      [ -d "$z" ] || continue
      echo 1 > "$z/reset" 2>/dev/null || true
    done
  fi
}
zram_supported(){
  [ -e /dev/zram0 ] && return 0
  command -v modprobe >/dev/null 2>&1 && modprobe zram >/dev/null 2>&1 || true
  [ -e /dev/zram0 ] && return 0
  [ -w /sys/class/zram-control/hot_add ] && return 0
  return 1
}
create_zram_swap(){
  local mb="$1" zdev=""
  if [ -e /dev/zram0 ]; then
    zdev="/dev/zram0"
  elif [ -w /sys/class/zram-control/hot_add ]; then
    local id
    id="$(cat /sys/class/zram-control/hot_add 2>/dev/null || true)"
    [ -n "$id" ] && zdev="/dev/zram${id}"
  fi
  [ -z "$zdev" ] && return 1
  local zn="${zdev#/dev/}"
  echo 1 > "/sys/block/${zn}/reset" 2>/dev/null || true
  [ -w "/sys/block/${zn}/comp_algorithm" ] && echo lz4 > "/sys/block/${zn}/comp_algorithm" 2>/dev/null || true
  echo "$((mb*1024*1024))" > "/sys/block/${zn}/disksize" 2>/dev/null || return 1
  mkswap "$zdev" >/dev/null 2>&1 || return 1
  swapon "$zdev" >/dev/null 2>&1 || return 1
}
create_swap_dd(){
  local mb="$1"
  dd if=/dev/zero of=/swapfile bs=1M count="$mb" status=none 2>"$SWAP_LOG" || return 1
  chmod 600 /swapfile || return 1
  mkswap /swapfile >/dev/null 2>&1 || return 1
  swapon /swapfile >/dev/null 2>&1 || return 1
  grep -q "^/swapfile[[:space:]]" /etc/fstab 2>/dev/null || echo "/swapfile none swap sw 0 0" >> /etc/fstab
}
create_swap_fallocate(){
  local mb="$1"
  command -v fallocate >/dev/null 2>&1 || return 1
  fallocate -l "${mb}M" /swapfile 2>"$SWAP_LOG" || return 1
  chmod 600 /swapfile || return 1
  mkswap -f /swapfile >/dev/null 2>&1 || return 1
  swapon /swapfile >/dev/null 2>&1 || return 1
  grep -q "^/swapfile[[:space:]]" /etc/fstab 2>/dev/null || echo "/swapfile none swap sw 0 0" >> /etc/fstab
}
create_swap_best(){
  local mb="${1:-128}"
  swap_disable_all
  if zram_supported && create_zram_swap "$mb"; then
    green "SWAP成功(ZRAM ${mb}MB)"
    return 0
  fi
  if create_swap_dd "$mb"; then
    green "SWAP成功(dd ${mb}MB)"
    return 0
  fi
  rm -f /swapfile
  if create_swap_fallocate "$mb"; then
    green "SWAP成功(fallocate ${mb}MB)"
    return 0
  fi
  red "SWAP失败"
  return 1
}
manage_swap(){
  while true; do
    cls
    local ram sw
    ram=$(awk '/MemTotal/{print int($2/1024)}' /proc/meminfo 2>/dev/null)
    [ -z "$ram" ] && ram=0
    sw=$(awk '/SwapTotal/{print int($2/1024)}' /proc/meminfo 2>/dev/null)
    [ -z "$sw" ] && sw=0
    echo -e "${C_WARN}=============== SWAP管理 ===============${C_RST}"
    echo "RAM: ${ram}MB  SWAP: ${sw}MB"
    echo "-----------------------------------------------"
    menu_item_auto "1" "安装SWAP"
    menu_item_auto "2" "卸载SWAP"
    menu_item_auto "0" "返回"
    echo "==============================================="
    prompt "请选择: " c
    case "$c" in
      1)
        prompt "大小MB(默认128): " mb
        mb=${mb:-128}
        [[ "$mb" =~ ^[0-9]+$ ]] && [ "$mb" -gt 0 ] && create_swap_best "$mb" || red "输入无效"
        pause
        ;;
      2)
        swap_disable_all
        green "已清理"
        pause
        ;;
      0) return ;;
      *) red "无效"; pause ;;
    esac
  done
}

# ========== Shortcut / Uninstall ==========
install_shortcut(){
  mkdir -p "$WORK"
  local mark="${WORK}/.shortcut_done"
  local local_script="${WORK}/manager.sh"
  local dst="/usr/local/bin/xray"
  local url1="${SCRIPT_URL:-https://raw.githubusercontent.com/cocihateu/Xray-lite/refs/heads/main/Xray_lite.sh}"
  local url2="https://raw.githubusercontent.com/cocihateu/Xray-lite/main/Xray_lite.sh"

  yellow "正在拉取脚本到本地: ${local_script}"
  if ! smart_download "$local_script" "$url1" 5000; then
    yellow "主地址失败，尝试备用地址..."
    smart_download "$local_script" "$url2" 5000 || { red "拉取失败: $url1"; return 1; }
  fi

  chmod 755 "$WORK" 2>/dev/null || true
  chmod 700 "$local_script" 2>/dev/null || chmod +x "$local_script" || true
  chown root:root "$local_script" 2>/dev/null || true

  mkdir -p /usr/local/bin
  cat > "$dst" <<'EOF'
#!/usr/bin/env bash
exec bash /etc/xray/manager.sh "$@"
EOF
  chmod 755 "$dst"
  chown root:root "$dst" 2>/dev/null || true

  touch "$mark"
  chmod 600 "$mark" 2>/dev/null || true
  green "快捷方式已创建：xray -> /etc/xray/manager.sh"
}

full_uninstall(){
  svc stop tunnel-argo
  svc disable tunnel-argo
  svc stop xray
  svc disable xray
  stop_service_monitor || true

  pkill -f '/etc/xray/argo tunnel' >/dev/null 2>&1 || true
  pkill -f '/etc/xray/argo_start.sh' >/dev/null 2>&1 || true
  pkill -x xray >/dev/null 2>&1 || true

  rm -f /etc/init.d/tunnel-argo /etc/systemd/system/tunnel-argo.service
  rm -f /etc/init.d/xray /etc/systemd/system/xray.service

  command -v systemctl >/dev/null 2>&1 && {
    systemctl daemon-reload >/dev/null 2>&1 || true
    systemctl reset-failed >/dev/null 2>&1 || true
  }

  local clr_swap
  prompt "是否同时清理SWAP? (y/N): " clr_swap
  case "${clr_swap:-N}" in
    y|Y|yes|YES)
      swap_disable_all >/dev/null 2>&1 || true
      yellow "SWAP 已清理"
      ;;
    *)
      yellow "已跳过 SWAP 清理"
      ;;
  esac

  rm -f /usr/local/bin/xray
  rm -rf "$WORK"
  green "已彻底卸载（服务/配置/快捷方式/监控/Cloudflare Token缓存）"
}

# ========== Outbound menu ==========
manage_outbound_menu(){
  while true; do
    cls
    local v6_list_json v6_disp
    v6_list_json="$(build_v6_domains_json)"
    v6_disp="$(echo "$v6_list_json" | jq -r 'join(",")')"
    [ -z "$v6_disp" ] && v6_disp="（空）"
    echo -e "${C_WARN}========== 出站管理（Xray）==========${C_RST}"
    echo -e "默认出站: \033[1;36mIPv4\033[0m"
    echo -e "IPv6 出站(严格): \033[1;36m${v6_disp}\033[0m"
    echo -e "YouTube V6 出站: \033[1;36m$( [ "$YOUTUBE_MODE" = "2" ] && echo '开启(严格)' || echo '关闭' )\033[0m"
    echo "-----------------------------------------------"
    menu_item_auto "1" "设置 YouTube V6 出站"
    menu_item_auto "2" "管理 IPv6 出站列表"
    menu_item_auto "0" "返回"
    echo "==============================================="
    prompt "请选择: " c
    case "$c" in
      1)
        prompt "输入模式(1=关闭 2=开启(严格)): " m
        case "$m" in
          1) YOUTUBE_MODE=1; green "已关闭 YouTube V6 出站" ;;
          2) YOUTUBE_MODE=2; green "已开启 YouTube V6 出站(严格)" ;;
          *) red "输入无效" ;;
        esac
        save_outbound
        apply_policy_all
        pause
        ;;
      2)
        while true; do
          cls
          local list_json list_disp
          list_json="$(build_v6_domains_json)"
          list_disp="$(echo "$list_json" | jq -r 'join(",")')"
          [ -z "$list_disp" ] && list_disp="（空）"
          echo -e "${C_WARN}===== IPv6 出站列表（严格） =====${C_RST}"
          echo -e "当前列表: \033[1;36m${list_disp}\033[0m"
          echo "-----------------------------------------------"
          menu_item_auto "1" "添加域名"
          menu_item_auto "2" "删除域名"
          menu_item_auto "0" "返回"
          echo "==============================================="
          prompt "请选择: " d
          case "$d" in
            1)
              prompt "输入域名(逗号分隔，支持批量): " s
              [ -z "$s" ] && { red "不能为空"; pause; continue; }
              if [ -z "$V6_SITES" ]; then
                V6_SITES="$s"
              else
                V6_SITES="${V6_SITES},${s}"
              fi
              V6_SITES="$(echo "$V6_SITES" | sed 's/,,/,/g; s/^,//; s/,$//')"
              save_outbound
              apply_policy_all
              green "已添加并应用"
              pause
              ;;
            2)
              if [ "$(echo "$list_json" | jq 'length')" -eq 0 ]; then
                red "列表为空"
                pause
                continue
              fi
              echo "当前 IPv6 出站域名："
              echo "$list_json" | jq -r '.[]' | nl -w2 -s'. '
              echo "输入序号（支持 1,3,5 ）或 a 全删，0取消"
              prompt "输入: " list
              if [[ "$list" =~ ^[aA]$ ]]; then
                V6_SITES=""
                save_outbound
                apply_policy_all
                green "已全删并应用"
                pause
                continue
              fi
              [ "$list" = "0" ] && continue
              local IFS=',' one target delset=""
              for one in $list; do
                one="$(echo "$one" | sed 's/ //g')"
                [[ "$one" =~ ^[0-9]+$ ]] || continue
                target="$(echo "$list_json" | jq -r ".[$((one-1))] // empty")"
                [ -n "$target" ] && delset="${delset}${target}"$'\n'
              done
              [ -z "$delset" ] && { red "无有效序号"; pause; continue; }
              local new_json
              new_json="$(echo "$list_json" | jq -r --argjson delset "$(echo "$delset" | jq -Rsc 'split("\n") | map(select(length>0))')" '. - $delset')"
              V6_SITES="$(echo "$new_json" | jq -r 'join(",")')"
              save_outbound
              apply_policy_all
              green "已删除并应用"
              pause
              ;;
            0) break ;;
            *) red "无效"; pause ;;
          esac
        done
        ;;
      0) return ;;
      *) red "无效"; pause ;;
    esac
  done
}

# ========== Xray menu ==========
xray_menu(){
  while true; do
    cls
    load_cf_mode
    local xs as hs rs cm
    if [ -x "$XRAY_BIN" ]; then
      xs=$(is_running xray && echo "\033[1;36m运行中\033[0m" || echo "${C_BAD}未启动${C_RST}")
    else
      xs="${C_BAD}未安装${C_RST}"
    fi
    if service_exists tunnel-argo; then
      as=$(is_running tunnel-argo && echo "\033[1;36m运行中\033[0m" || echo "${C_BAD}未启动${C_RST}")
    else
      as="${C_BAD}未配置${C_RST}"
    fi
    init_hy2_list
    if [ "$(jq 'length' "$HY2_LIST" 2>/dev/null || echo 0)" -gt 0 ]; then
      hs="\033[1;36m已配置\033[0m"
    else
      hs="${C_BAD}未配置${C_RST}"
    fi
    init_reality_list
    if [ "$(jq 'length' "$REALITY_LIST" 2>/dev/null || echo 0)" -gt 0 ]; then
      rs="\033[1;36m已配置\033[0m"
    else
      rs="${C_BAD}未配置${C_RST}"
    fi
    cm="$(cf_mode_display)"

    echo -e "${C_OK}=============== Xray管理 ===============${C_RST}"
    echo -e "Xray: ${xs}   Argo: ${as}   HY2: ${hs}   Reality: ${rs}"
    echo -e "CF加速模式: \033[1;36m${cm}\033[0m"
    if [ -n "${CF_API_TOKEN:-}" ] || load_cf_api >/dev/null 2>&1; then
      echo -e "CF自动配置: \033[1;36m已保存Token\033[0m"
    else
      echo -e "CF自动配置: ${C_BAD}未配置Token${C_RST}"
    fi
    echo "-----------------------------------------------"
    menu_row2_auto "1"  "配置CF加速"         "8"  "实时日志"
    menu_row2_auto "2"  "配置Reality"        "9"  "查看节点"
    menu_row2_auto "3"  "配置HY2"            "10" "修改UUID"
    menu_row2_auto "4"  "配置Socks5"         "11" "卸载Xray"
    menu_row2_auto "5"  "重启Argo"           "12" "更新Xray"
    menu_row2_auto "6"  "重启Xray"           "13" "设置CF令牌"
    menu_row2_auto "7"  "卸载Argo"           "0"  "返回"
    echo "==============================================="
    prompt "请选择: " c
    case "$c" in
      1) configure_cf_accel ;;
      2) manage_reality ;;
      3) manage_hy2 ;;
      4) manage_socks5 ;;
      5)
        service_exists tunnel-argo && svc restart tunnel-argo && green "Argo 已重启" || red "Argo未安装"
        pause
        ;;
      6)
        service_exists xray && svc restart xray && green "Xray 已重启" || red "Xray未安装"
        pause
        ;;
      7)
        uninstall_argo
        pause
        ;;
      8) foreground_xray_log ;;
      9)
        show_xray_nodes
        pause
        ;;
      10)
        prompt "新UUID(回车自动): " u
        [ -z "$u" ] && u="$(gen_uuid)"
        set_xray_uuid "$u"
        pause
        ;;
      11)
        uninstall_xray_only
        pause
        ;;
      12)
        update_xray_core
        pause
        ;;
      13)
        rm -f "$CF_API_BOOTSTRAP_DONE" 2>/dev/null || true
        CF_API_TOKEN=""
        cf_require_token
        pause
        ;;
      0) return ;;
      *) red "无效"; pause ;;
    esac
  done
}

# ========== System info ==========
detect_virt_name(){
  local v=""

  if command -v systemd-detect-virt >/dev/null 2>&1; then
    v="$(systemd-detect-virt 2>/dev/null || true)"
    case "${v,,}" in
      podman) echo "PODMAN"; return ;;
      docker) echo "DOCKER"; return ;;
      lxc) echo "LXC"; return ;;
      containerd) echo "CONTAINERD"; return ;;
      openvz|kvm|qemu|vmware|xen) echo "${v^^}"; return ;;
      container) ;;
      none|"") ;;
      *) echo "${v^^}"; return ;;
    esac
  fi

  if [ -r /run/systemd/container ]; then
    v="$(cat /run/systemd/container 2>/dev/null || true)"
    case "${v,,}" in
      podman) echo "PODMAN"; return ;;
      docker) echo "DOCKER"; return ;;
      lxc) echo "LXC"; return ;;
      containerd) echo "CONTAINERD"; return ;;
      "") ;;
      *) echo "${v^^}"; return ;;
    esac
  fi

  if tr '\0' '\n' </proc/1/environ 2>/dev/null | grep -qi '^container=podman$'; then echo "PODMAN"; return; fi
  if tr '\0' '\n' </proc/1/environ 2>/dev/null | grep -qi '^container=docker$'; then echo "DOCKER"; return; fi
  if tr '\0' '\n' </proc/1/environ 2>/dev/null | grep -qi '^container=lxc$'; then echo "LXC"; return; fi
  if tr '\0' '\n' </proc/1/environ 2>/dev/null | grep -qi '^container=containerd$'; then echo "CONTAINERD"; return; fi

  if grep -qaE '(podman|docker|containerd|kubepods|lxc)' /proc/1/cgroup 2>/dev/null; then
    if grep -qa 'podman' /proc/1/cgroup 2>/dev/null; then echo "PODMAN"; return; fi
    if grep -qa 'docker' /proc/1/cgroup 2>/dev/null; then echo "DOCKER"; return; fi
    if grep -qa 'containerd\|kubepods' /proc/1/cgroup 2>/dev/null; then echo "CONTAINERD"; return; fi
    if grep -qa 'lxc' /proc/1/cgroup 2>/dev/null; then echo "LXC"; return; fi
    echo "CONTAINER"; return
  fi

  [ -f /run/.containerenv ] && { echo "PODMAN"; return; }
  [ -f /.dockerenv ] && { echo "DOCKER"; return; }

  if grep -qaE '(container|podman|docker)' /proc/1/mountinfo 2>/dev/null; then
    echo "CONTAINER"
    return
  fi

  echo "UNKNOWN"
}
arch_disp(){
  case "$(uname -m)" in
    x86_64|amd64) echo "x64" ;;
    i?86) echo "x86" ;;
    aarch64|arm64) echo "arm64" ;;
    armv7l|armv7|armhf) echo "armv7" ;;
    armv6l|armv6) echo "armv6" ;;
    s390x) echo "s390x" ;;
    riscv64) echo "riscv64" ;;
    *) uname -m ;;
  esac
}
os_version_disp(){
  local osv
  if is_alpine; then
    osv="Alpine $(cat /etc/alpine-release 2>/dev/null || echo "")"
  elif [ -f /etc/os-release ]; then
    . /etc/os-release
    if [ -n "${ID:-}" ] && [ -n "${VERSION_ID:-}" ]; then
      osv="$(echo "$ID" | sed 's/^[a-z]/\U&/') ${VERSION_ID}"
    else
      osv="${PRETTY_NAME:-Linux}"
    fi
  else
    osv="Linux"
  fi
  echo "$osv"
}
kernel_disp(){
  cut -d- -f1 < /proc/sys/kernel/osrelease 2>/dev/null || uname -r
}
cpu_model_disp(){
  local model
  model="$(awk -F: '
    /model name/ {gsub(/^[ \t]+/, "", $2); print $2; exit}
    /Hardware/   {gsub(/^[ \t]+/, "", $2); print $2; exit}
    /Processor/  {gsub(/^[ \t]+/, "", $2); print $2; exit}
  ' /proc/cpuinfo 2>/dev/null)"
  [ -z "$model" ] && model="$(uname -m)"
  echo "$model"
}
cpu_cores_disp(){
  nproc 2>/dev/null || awk '/^processor/{n++} END{print (n?n:1)}' /proc/cpuinfo 2>/dev/null
}
cpu_usage_percent(){
  local user nice system idle iowait irq softirq steal guest guest_nice
  local total idle_all diff_total diff_idle usage
  local s1_total s1_idle s2_total s2_idle
  read -r _ user nice system idle iowait irq softirq steal guest guest_nice < /proc/stat
  total=$((user+nice+system+idle+iowait+irq+softirq+steal))
  idle_all=$((idle+iowait))
  if [ "${CPU_LAST_TOTAL:-0}" -eq 0 ] || [ "${CPU_LAST_IDLE:-0}" -eq 0 ]; then
    s1_total="$total"
    s1_idle="$idle_all"
    sleep 0.2
    read -r _ user nice system idle iowait irq softirq steal guest guest_nice < /proc/stat
    s2_total=$((user+nice+system+idle+iowait+irq+softirq+steal))
    s2_idle=$((idle+iowait))
    diff_total=$((s2_total-s1_total))
    diff_idle=$((s2_idle-s1_idle))
    CPU_LAST_TOTAL="$s2_total"
    CPU_LAST_IDLE="$s2_idle"
    if [ "$diff_total" -le 0 ]; then echo "0"; return; fi
    usage=$(( (100*(diff_total-diff_idle))/diff_total ))
    [ "$usage" -lt 0 ] && usage=0
    [ "$usage" -gt 100 ] && usage=100
    echo "$usage"
    return
  fi
  diff_total=$((total-CPU_LAST_TOTAL))
  diff_idle=$((idle_all-CPU_LAST_IDLE))
  CPU_LAST_TOTAL="$total"
  CPU_LAST_IDLE="$idle_all"
  if [ "$diff_total" -le 0 ]; then echo "0"; return; fi
  usage=$(( (100*(diff_total-diff_idle))/diff_total ))
  [ "$usage" -lt 0 ] && usage=0
  [ "$usage" -gt 100 ] && usage=100
  echo "$usage"
}
mem_swap_used_disp(){
  awk '
    /MemTotal/      {mt=$2}
    /MemAvailable/  {ma=$2}
    /SwapTotal/     {st=$2}
    /SwapFree/      {sf=$2}
    END{
      mu=mt-ma;
      if (mt>1024*1024) mtxt=sprintf("%.1fG/%.1fG", mu/1024/1024, mt/1024/1024);
      else              mtxt=sprintf("%.0fM/%.0fM", mu/1024, mt/1024);
      if (st>0) {
        su=st-sf;
        if (st>1024*1024) stxt=sprintf("%.1fG/%.1fG", su/1024/1024, st/1024/1024);
        else              stxt=sprintf("%.0fM/%.0fM", su/1024, st/1024);
      } else {
        stxt="";
      }
      printf "%s|%s", mtxt, stxt;
    }
  ' /proc/meminfo 2>/dev/null
}

# ========== Main ==========
main_menu(){
  ensure_deps || { red "依赖安装失败，请检查网络/源"; exit 1; }
  mkdir -p "$WORK"
  load_state
  init_hy2_list
  init_reality_list

  load_ip_cache >/dev/null 2>&1 || true
  [ "$IP_CHECKED" = "1" ] || {
    cls
    echo -e "\033[1;33mIP信息加载中，请稍候...\033[0m"
    check_ip || { red "IP检测失败，已跳过（不影响进入菜单）"; sleep 1; }
  }

  while true; do
    cls
    [ -f "$IPCACHE" ] && {
      local mt
      mt=$(stat -c %Y "$IPCACHE" 2>/dev/null || echo 0)
      [ "$mt" -gt "${IP_CACHE_MTIME:-0}" ] && IP_CACHE_MTIME="$mt" && load_ip_cache >/dev/null 2>&1 || true
    }

    local osver arch ker virt cpu_model cpu_cores cpu_use ms u4 u6
    local mem swap
    osver="$(os_version_disp)"
    arch="$(arch_disp)"
    ker="$(kernel_disp)"
    virt="$(detect_virt_name)"
    cpu_model="$(cpu_model_disp)"
    cpu_cores="$(cpu_cores_disp)"
    cpu_use="$(cpu_usage_percent)"
    ms="$(mem_swap_used_disp)"
    mem="${ms%%|*}"
    swap="${ms#*|}"

    if [ -n "${WAN4:-}" ]; then
      u4="${EMOJI4} ${COUNTRY4} ${WAN4}"
      [ -n "${ISP4:-}" ] && [ "${ISP4}" != "unknown" ] && u4="${u4} | ${ISP4}"
      u4="\033[1;36m${u4}\033[0m"
    else
      u4="${C_BAD}未检测到${C_RST}"
    fi

    if [ -n "${WAN6:-}" ]; then
      u6="${EMOJI6} ${COUNTRY6} ${WAN6}"
      [ -n "${ISP6:-}" ] && [ "${ISP6}" != "unknown" ] && u6="${u6} | ${ISP6}"
      u6="\033[1;36m${u6}\033[0m"
    else
      u6="${C_BAD}未检测到${C_RST}"
    fi

    echo -e "${C_DIM}================ 系统信息 ================${C_RST}"
    echo -e "OS   : \033[1;36m${osver} | ${arch} | ${ker} | ${virt}\033[0m"
    echo -e "CPU  : \033[1;36m${cpu_model} | ${cpu_cores}C | ${cpu_use}%\033[0m"
    echo -e "Mem  : \033[1;36m${mem}\033[0m"
    [ -n "$swap" ] && echo -e "Swap : \033[1;36m${swap}\033[0m"
    echo "-----------------------------------------------"
    echo -e "IPv4 : ${u4}"
    echo -e "IPv6 : ${u6}"
    echo -e "${C_DIM}==========================================${C_RST}"
    echo

    menu_row2_auto "1" "管理Xray"   "6" "管理SWAP"
    menu_row2_auto "2" "管理出站"   "8" "创建快捷"
    menu_row2_auto "3" "服务监控"   "9" "彻底卸载"
    menu_row2_auto "0" "退出"
    echo "==============================================="
    prompt "请选择: " c
    case "$c" in
      1) xray_menu ;;
      2) manage_outbound_menu ;;
      3) manage_service_monitor ;;
      0) cls; exit 0 ;;
      6) manage_swap ;;
      8) install_shortcut; pause ;;
      9) full_uninstall; pause ;;
      *) red "无效"; pause ;;
    esac
  done
}

trap 'echo; cls; red "已中断"; exit 130' INT TERM
main_menu
