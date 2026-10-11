#!/bin/bash
# login-report — helper umum (config, log, warna, validasi)
# shellcheck disable=SC2034,SC1091
LR_VERSION="1.0.0"

# ── warna ───────────────────────────────────────────────────
if [ -t 1 ] && [ "${NO_COLOR:-}" != "1" ]; then
  R=$'\e[31m'; G=$'\e[32m'; Y=$'\e[33m'; B=$'\e[34m'; C=$'\e[36m'; N=$'\e[0m'; BOLD=$'\e[1m'
else R=""; G=""; Y=""; B=""; C=""; N=""; BOLD=""; fi

lr_die(){ printf '%s[!]%s %s\n' "$R" "$N" "$*" >&2; exit 1; }
lr_ok(){  printf '%s[+]%s %s\n' "$G" "$N" "$*"; }
lr_warn(){ printf '%s[!]%s %s\n' "$Y" "$N" "$*"; }
lr_head(){ printf '\n%s%s%s\n' "$BOLD$C" "$*" "$N"; }
lr_line(){ printf '%s\n' "--------------------------------------------"; }

# ── konfigurasi ─────────────────────────────────────────────
LR_CONF=/etc/login-report/config.conf
lr_load_conf(){
  [ -r "$LR_CONF" ] || { printf '[!] config tidak ada: %s\n' "$LR_CONF" >&2; return 1; }
  local line key val
  while IFS= read -r line; do
    case "$line" in ''|'#'*) continue ;; esac
    key=${line%%=*}; val=${line#*=}
    key=$(printf '%s' "$key" | tr -d ' ' | tr -c 'A-Za-z0-9_' '_')
    case "$key" in
      BOT_TOKEN|CHAT_ID|ENABLED|INTERVAL_MIN|DAILY_AT|SEND_SSH|SEND_VMESS|SEND_VLESS|SEND_TROJAN|XRAY_LOG_MINUTES|DOMAIN|INFO_COLUMNS|XRAY_ACCESS_LOG|XRAY_CONFIG|XRAY_API_ADDR|CURL_RETRY|CURL_TIMEOUT)
        # buang kutip pembungkus ("..." atau '...')
        val=${val%\"}; val=${val#\"}; val=${val%\'}; val=${val#\'}
        eval "$key=\$val" ;;
    esac
  done < "$LR_CONF"
  return 0
}

# tulis nilai ke config (preserve komentar & urutan, tanpa sed -i pada file asli)
lr_set_conf(){
  local key="$1" val="$2" tmp
  [ -r "$LR_CONF" ] || return 1
  [ -w "$LR_CONF" ] || return 1
  val=$(printf '%s' "$val" | tr -d '\n\r')
  tmp=$(mktemp)
  awk -v k="$key" -v v="$val" '
    BEGIN{ done=0; FS="="; OFS="=" }
    /^[A-Za-z_][A-Za-z0-9_]*=/ {
      key=$1
      if (key==k && !done) { $0=k"="v; done=1 }
    }
    { print }
    END{ if(!done) print k"="v }
  ' "$LR_CONF" > "$tmp"
  chmod --reference="$LR_CONF" "$tmp" 2>/dev/null || chmod 600 "$tmp"
  mv -f "$tmp" "$LR_CONF"
  # sinkronkan variabel di memori supaya pemanggil (menu/timer) langsung pakai nilai baru
  eval "$key=\$val"
}

# ── logging (token TIDAK pernah masuk log) ──────────────────
LR_LOG=/var/log/login-report.log
lr_log(){ printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LR_LOG" 2>/dev/null || true; }

# ── validasi ────────────────────────────────────────────────
lr_valid_interval(){ case "$1" in 5|10|15|30|60|180|360|720|1440) return 0 ;; *) return 1 ;; esac; }
lr_valid_hhmm(){ [[ "$1" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]]; }

# ── mask token: tampilkan prefix, sisanya **** ──────────────
lr_mask_token(){
  local t="${1:-}"
  [ -z "$t" ] && { echo "-"; return; }
  case "$t" in
    *:*) printf '%s:%s****' "${t%%:*}" "$(printf '%s' "${t#*:}" | cut -c1-3)" ;;
    *)   printf '%s****' "$(printf '%s' "$t" | cut -c1-4)" ;;
  esac
}

lr_valid_chat_id(){ [[ "${1:-}" =~ ^-?[0-9]+$ ]]; }