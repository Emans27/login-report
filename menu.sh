#!/bin/bash
# login-report — menu "lreport"
# shellcheck disable=SC2034,SC2154,SC1091
set -uo pipefail
LR_BASE=/opt/login-report
. "$LR_BASE/lib/common.sh"
. "$LR_BASE/lib/core.sh"

# jangan jalan sebagai service (menu butuh terminal)
if [ "${1:-}" = "--service" ]; then main; exit $?; fi

pause(){ echo; read -r -p "  Enter untuk lanjut..." _ || true; }

# ── tampilan status ringkas ─────────────────────────────────
lr_show_status(){
  lr_load_conf
  local timer_enabled
  timer_enabled=$(systemctl is-enabled login-report.timer 2>/dev/null || echo disabled)
  printf '  Status          : %s\n' "$([ "${ENABLED:-off}" = on ] && echo "${G}ON${N}" || echo "${Y}OFF${N}")"
  printf '  Timer enabled   : %s\n' "$timer_enabled"
  if [ -n "${DAILY_AT:-}" ]; then printf '  Jadwal berikut  : harian %s\n' "$DAILY_AT"
  else printf '  Jadwal berikut  : tiap %s menit\n' "${INTERVAL_MIN:-30}"; fi
  printf '  Interval        : %s menit%s\n' "${INTERVAL_MIN:-30}" \
    "$([ "${INTERVAL_MIN:-30}" -ge 1440 ] 2>/dev/null && echo ' (harian 00:00)')"
  [ -n "${DAILY_AT:-}" ] && printf '  Jam harian      : %s\n' "$DAILY_AT"
  printf '  Token           : %s\n' "$(lr_mask_token "${BOT_TOKEN:-}")"
  printf '  Chat ID         : %s\n' "${CHAT_ID:--}"
  printf '  Protokol        : SSH=%s VMESS=%s VLESS=%s TROJAN=%s\n' \
    "${SEND_SSH:-on}" "${SEND_VMESS:-on}" "${SEND_VLESS:-on}" "${SEND_TROJAN:-on}"
  printf '  Window log      : %s menit\n' "${XRAY_LOG_MINUTES:-15}"
  printf '  Stats API       : %s\n' "$(lr_xray_stats_ready && echo 'READY (per-inbound)' || echo "${Y}TIDAK — per-user butuh loglevel detail${N}")"
  printf '  Log file        : %s\n' "$LR_LOG"
}

# ── menu utama ──────────────────────────────────────────────
while true; do
  clear 2>/dev/null || true
  printf '%s\n' "+--------------------------------------------------+"
  printf '%s\n' "|   LOGIN REPORT v$LR_VERSION   by SUNEK VPN   |"
  printf '%s\n' "+--------------------------------------------------+"
  echo
  lr_show_status
  echo
  printf '%s\n' "  1) Set Bot Token & Chat ID"
  printf '%s\n' "  2) Atur interval / jam laporan"
  printf '%s\n' "  3) Aktifkan / matikan laporan"
  printf '%s\n' "  4) Pilih protokol yang dikirim"
  printf '%s\n' "  5) Kirim laporan test sekarang"
  printf '%s\n' "  6) Lihat status detail"
  printf '%s\n' "  7) Uninstall"
  printf '%s\n' "  0) Keluar"
  echo
  printf '  Pilih: '
  read -r c || exit 0
  case "$c" in
    1) # ── token & chat ────────────────────────────────────
      lr_load_conf
      echo
      echo "  Masukkan Bot Token dari @BotFather"
      printf '  Token (kosongkan utk batal): '; read -r t
      [ -z "$t" ] && continue
      t=$(printf '%s' "$t" | tr -d ' \t\r\n')
      [ -z "$t" ] && { lr_warn "Token kosong, dibatalkan"; continue; }
      lr_set_conf BOT_TOKEN "$t"; lr_log "BOT_TOKEN diperbarui (redacted)"
      printf '  Chat ID (mis. 1732345678): '; read -r cid
      cid=$(echo "$cid" | tr -d ' ')
      if lr_valid_chat_id "$cid"; then
        lr_set_conf CHAT_ID "$cid"; lr_log "CHAT_ID diperbarui"
      else lr_warn "Chat ID tidak valid"; fi
      # verifikasi token
      local_ok=$(curl -4 -sS --max-time 10 "https://api.telegram.org/bot${t}/getMe" 2>/dev/null | jq -r '.ok // false' 2>/dev/null)
      [ "$local_ok" = "true" ] && lr_ok "Token valid" || lr_warn "Token tidak diverifikasi (cek jaringan/token)"
      lr_set_conf XRAY_ACCESS_LOG "$XRAY_ACCESS_LOG"; ;;
    2) # ── interval ────────────────────────────────────────
      lr_load_conf; echo
      printf '%s\n' "  1) 5 menit     2) 10 menit    3) 15 menit   4) 30 menit"
      printf '%s\n' "  5) 1 jam      6) 3 jam       7) 6 jam       8) 12 jam"
      printf '%s\n' "  9) 24 jam    10) jam tertentu harian  11) manual (menit)"
      printf '  Pilih: '; read -r k
      case "$k" in
        1) m=5;;   2) m=10;;  3) m=15;;  4) m=30;;
        5) m=60;;  6) m=180;; 7) m=360;; 8) m=720;;
        9) m=1440;;
        10) printf '  Jam (HH:MM, 24 jam): '; read -r h
            if lr_valid_hhmm "$h"; then
              lr_set_conf DAILY_AT "$h"; lr_set_conf INTERVAL_MIN "${INTERVAL_MIN:-30}"
              lr_timer_apply; lr_ok "Jadwal harian $h diterapkan"; pause; continue
            else lr_warn "Format jam salah"; pause; continue; fi ;;
        11) printf '  Menit (1-1440): '; read -r m
            if ! [[ "$m" =~ ^[0-9]+$ ]] || [ "$m" -lt 1 ] || [ "$m" -gt 1440 ]; then
              lr_warn "Interval tidak valid (harus 1-1440 menit)"; pause; continue
            fi ;;
        *) continue ;;
      esac
      [ "$m" = "1440" ] && m=1440
      lr_set_conf INTERVAL_MIN "$m"; lr_set_conf DAILY_AT ""
      lr_timer_apply; lr_ok "Interval ${m} menit diterapkan"; pause ;;
    3) # ── on/off ──────────────────────────────────────────
      lr_load_conf
      if [ "${ENABLED:-off}" = "on" ]; then
        lr_set_conf ENABLED off; lr_timer_apply; lr_ok "Laporan dimatikan"
      else
        if [ -z "${BOT_TOKEN:-}" ] || [ -z "${CHAT_ID:-}" ]; then
          lr_warn "Token/Chat belum lengkap"; pause; continue
        fi
        lr_set_conf ENABLED on; lr_timer_apply; lr_ok "Laporan diaktifkan"
      fi
      pause ;;
    4) # ── protokol ────────────────────────────────────────
      lr_load_conf; echo
      printf '%s\n' "  Toggle masing-masing dengan y/n:"
      for p in SSH VMESS VLESS TROJAN; do
        var="SEND_$p"; cur="${!var:-on}"
        printf '  %s [%s] (y/n): ' "$p" "$cur"; read -r a
        case "$a" in y|Y) lr_set_conf "$var" on;; n|N) lr_set_conf "$var" off;; esac
      done
      lr_ok "Protokol diperbarui"; pause ;;
    5) # ── test kirim ──────────────────────────────────────
      lr_load_conf
      if [ -z "${BOT_TOKEN:-}" ] || [ -z "${CHAT_ID:-}" ]; then
        lr_warn "Token/Chat belum lengkap (menu 1)"; pause; continue
      fi
      echo "  Kirim test ke chat ${CHAT_ID} ..."
      if lr_send_report; then lr_ok "Terkirim — cek Telegram"; else lr_warn "Gagal kirim (cek log: $LR_LOG)"; fi
      pause ;;
    6) # ── status detail ───────────────────────────────────
      lr_load_conf; echo; lr_show_status; echo
      [ -s "$LR_LOG" ] && { echo "  20 baris log terakhir:"; tail -20 "$LR_LOG" | sed "s/\(BOT_TOKEN[^ ]*\).*/\1**REDACTED**/;s/\(bot[0-9]*:\)[A-Za-z0-9_-]*/\1REDACTED/g;s/[0-9]\{9,\}:[A-Za-z0-9_-]\{30,\}/TOKEN_REDACTED/g; s/^/    /"; }
      echo
      pause ;;
    7) # ── uninstall ───────────────────────────────────────
      echo; lr_warn "Ini akan menghapus SELURUH milik login-report"
      printf '  Ketik "uninstall" untuk lanjut: '; read -r u
      if [ "$u" = "uninstall" ]; then
        systemctl stop login-report.timer 2>/dev/null || true
        systemctl disable login-report.timer 2>/dev/null || true
        systemctl stop login-report.service 2>/dev/null || true
        systemctl disable login-report.service 2>/dev/null || true
        systemctl daemon-reload
        rm -f /etc/systemd/system/login-report.service /etc/systemd/system/login-report.timer
        rm -f /usr/local/bin/lreport
        rm -rf /opt/login-report /etc/login-report
        rm -f /var/log/login-report.log
        lr_ok "Uninstall selesai — tunneling lama tidak disentuh"
        exit 0
      else lr_warn "Dibatalkan"; fi
      pause ;;
    0) exit 0 ;;
    *) : ;;
  esac
done