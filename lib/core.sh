#!/bin/bash
# login-report — core: kirim laporan ke Telegram + kelola schedule
# Dipanggil oleh: lreport (menu), login-report.service (systemd)
# shellcheck disable=SC2034,SC2154,SC1091
set -uo pipefail

LR_BASE=/opt/login-report
. "$LR_BASE/lib/common.sh"
. "$LR_BASE/lib/collector.sh"

# ── kirim ke Telegram (retry 2x, HTML, split >4000 char) ────
lr_tg_send(){
  local chat="$1" msg="$2" resp code desc i
  [ -z "${BOT_TOKEN:-}" ] && { lr_log "gagal: BOT_TOKEN kosong"; return 3; }
  [ -z "$chat" ] && { lr_log "gagal: CHAT_ID kosong"; return 3; }

  local i=0
  while [ "$i" -le "${CURL_RETRY:-2}" ]; do
    resp=$(curl -4 -sS --max-time "${CURL_TIMEOUT:-20}" \
      "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
      -d "chat_id=${chat}" \
      --data-urlencode "text=${msg}" \
      -d "parse_mode=HTML" \
      -d "disable_web_page_preview=true" 2>/dev/null || true)
    code=$(printf '%s' "$resp" | jq -r '.ok // false' 2>/dev/null)
    if [ "$code" = "true" ]; then return 0; fi
    desc=$(printf '%s' "$resp" | jq -r '.description // empty' 2>/dev/null)
    [ -n "$desc" ] && lr_log "telegram error: $desc"
    i=$((i+1)); sleep 1
  done
  lr_log "gagal kirim setelah $((CURL_RETRY+1)) percobaan (chat=$chat)"
  return 1
}

# kirim laporan: satu pesan per protokol
lr_send_report(){
  local chat="${CHAT_ID:-}"
  [ -z "$chat" ] && { lr_warn "CHAT_ID belum diatur"; return 2; }

  local -a msgs=()
  lr_build_messages msgs
  [ "${#msgs[@]}" -eq 0 ] && { lr_log "tidak ada blok yang aktif"; return 1; }

  # bila satu pesan terlalu panjang, pecah lagi di batas <pre>
  local parts=() cur="" chunk m
  for m in "${msgs[@]}"; do
    if [ "${#m}" -le 3900 ]; then parts+=("$m"); continue; fi
    cur=""
    while IFS= read -r chunk; do
      [ -z "$chunk" ] && continue
      if [ $(( ${#cur} + ${#chunk} + 1 )) -gt 3800 ]; then
        parts+=("$cur"); cur="$chunk"
      else
        cur+="$chunk"
      fi
    done < <(lr_split_pre "$m")
    [ -n "$cur" ] && parts+=("$cur")
  done

  local n=0 failed=0 sent=0 w
  for w in "${parts[@]}"; do
    n=$((n+1))
    if lr_tg_send "$chat" "$w"; then sent=$((sent+1))
    else failed=1; fi
    # jeda antar pesan supaya tidak kena rate limit Telegram
    [ "$n" -lt "${#parts[@]}" ] && sleep "${SEND_DELAY:-1.5}"
  done
  if [ "$failed" -eq 1 ]; then
    lr_log "laporan GAGAL terkirim ($sent/$n pesan, chat $chat) — lihat error di atas"
    return 1
  fi
  lr_log "laporan terkirim ($n pesan, chat $chat)"
  return 0
}

# split html jadi potongan utuh per <pre>
lr_split_pre(){
  awk '
    /^<\/pre>$/ { buf=buf $0 ORS; print buf; buf=""; next }
    { buf=buf $0 ORS }
    END{ if(buf!="") print buf }
  '
}

# ── susun laporan ─────────────────────────────────────────
# Output: satu PESAN per protokol (SSH|VMESS|VLESS|TROJAN), setiap pesan = header + 1 blok.
# Header identitas hanya di pesan pertama.
# Kegunaan: lr_build_messages mengisi array MMGS[] (pass by name), dan
# lr_build_messages_print() mencetak semua pesan untuk CLI/preview.
lr_build_messages(){
  local ip dom isp header="" first=1 spec block out
  ip=$(lr_public_ip); dom=$(lr_domain); isp=$(lr_isp "$ip")
  header=$(printf '<pre>IP     : %s\nDOMAIN : %s\nISP    : %s\n</pre>' "$ip" "$dom" "$isp")

  # $1 = nama array output
  local __out="${1:-LR_MSGS}"
  eval "$__out=()"

  local specs=()
  [ "${SEND_SSH:-on}"    = "on" ] && specs+=("SSH")
  [ "${SEND_VMESS:-on}"  = "on" ] && specs+=("VMESS")
  [ "${SEND_VLESS:-on}"  = "on" ] && specs+=("VLESS")
  [ "${SEND_TROJAN:-on}" = "on" ] && specs+=("TROJAN")

  for spec in "${specs[@]}"; do
    case "$spec" in
      SSH) block=$(lr_ssh_block) ;;
      *)   block=$(lr_xray_block "$spec") ;;
    esac
    [ -z "$block" ] && continue
    out=""
    if [ "$first" = "1" ]; then out+="$header"$'\n'; first=0; fi
    out+="$block"
    eval "$__out+=(\"\$out\")"
  done
}

lr_build_messages_print(){
  local -a _m=()
  lr_build_messages _m
  local i
  for i in "${!_m[@]}"; do
    echo "########## PESAN $((i+1)) ##########"
    printf '%s\n' "${_m[$i]}"
  done
}

# kompatibilitas: satu string (dipakai menu/preview)
lr_build_html(){
  local -a _m=()
  lr_build_messages _m
  # preview gabungan (menu); pemisah antar pesan
  local out="" i
  for i in "${!_m[@]}"; do out+="${_m[$i]}"$'\n'; done
  printf '%s' "${out%$'\n'}"
}

# ── schedule systemd timer ──────────────────────────────────
lr_timer_apply(){
  # on-calendar based; dipanggil setiap INTERVAL_MIN/DAILY_AT berubah
  # Tulis unit lebih dulu supaya OnCalendar selalu sinkron walau laporan OFF
  local unit=/etc/systemd/system/login-report.timer oc="" m="${INTERVAL_MIN:-30}"
  if [ -n "${DAILY_AT:-}" ]; then
    oc="*-*-* ${DAILY_AT}:00"
  elif [ "$m" -ge 1440 ] 2>/dev/null; then
    # 24 jam sekali → tengah malam, bukan *:00/1440 yang tak valid
    oc="*-*-* 00:00:00"
  else
    oc="*-*-* *:00/${m}"
  fi
  cat > "$unit" <<EOF
[Unit]
Description=login-report schedule (auto-generated)
Documentation=man:systemd.timer(5)

[Timer]
OnCalendar=${oc}
Persistent=true
AccuracySec=1min
Unit=login-report.service

[Install]
WantedBy=timers.target
EOF
  systemctl daemon-reload

  if [ "${ENABLED:-off}" != "on" ]; then
    systemctl stop    login-report.timer 2>/dev/null || true
    systemctl disable login-report.timer 2>/dev/null || true
    return 0
  fi
  systemctl enable  login-report.timer >/dev/null 2>&1 || true
  systemctl restart login-report.timer >/dev/null 2>&1 || true
  return 0
}

# ── entry point CLI (dipakai systemd service) ───────────────
main(){
  lr_load_conf || exit 1
  if lr_send_report; then exit 0
  else
    lr_warn "pengiriman gagal — cek: lreport → 6 (status)"
    exit 1
  fi
}
# hanya jalan kalau dieksekusi langsung, bukan di-source (menu butuh fungsi ini)
if [ "${BASH_SOURCE[0]}" = "$0" ]; then main "$@"; fi
# TIDAK pakai exit di sini — file ini sering di-source oleh menu & test
: