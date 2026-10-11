#!/bin/bash
# login-report uninstaller — hapus semua milik tool login-report
# TIDAK menyentuh script/menu tunneling lain.
# shellcheck disable=SC2035,SC2046
set -euo pipefail

VERSION="1.0.0"
BIN=/usr/local/bin/lreport
ETC=/etc/login-report
LOG=/var/log/login-report.log

say(){ printf '%s\n' "$*"; }
hr(){ printf '%s\n' "════════════════════════════════════════"; }

if [ "$(id -u)" -ne 0 ]; then
  say "ERROR: harus root (sudo -i / su -)"
  exit 1
fi

hr
say "  login-report uninstaller v$VERSION"
hr

# ── konfirmasi ─────────────────────────────────────────────
if [ -t 0 ]; then
  read -r -p "Hapus login-report beserta config, timer, dan log? [y/N] " ans
  case "$ans" in
    y|Y|yes|YES) ;;
    *) say "Dibatalkan."; exit 0 ;;
  esac
fi

# ── hentikan timer & service ───────────────────────────────
say "▸ Stop timer & service..."
systemctl stop login-report.timer 2>/dev/null || true
systemctl disable login-report.timer 2>/dev/null || true
systemctl stop login-report.service 2>/dev/null || true
systemctl disable login-report.service 2>/dev/null || true
systemctl daemon-reload 2>/dev/null || true
say "  OK"

# ── hapus unit systemd ─────────────────────────────────────
say "▸ Hapus unit systemd..."
rm -f /etc/systemd/system/login-report.service
rm -f /etc/systemd/system/login-report.timer
say "  OK"

# ── hapus binary & config ──────────────────────────────────
say "▸ Hapus binary & config..."
rm -f "$BIN"
rm -rf "$ETC"
say "  OK"

# ── hapus log ──────────────────────────────────────────────
say "▸ Hapus log..."
rm -f "$LOG"
say "  OK"

# ── verifikasi tidak ada sisa ──────────────────────────────
say ""
hr
LEFT=0
for p in "$BIN" "$ETC" "$LOG" \
         /etc/systemd/system/login-report.service \
         /etc/systemd/system/login-report.timer; do
  if [ -e "$p" ]; then say "  SISA: $p"; LEFT=$((LEFT+1)); fi
done

if [ "$LEFT" -eq 0 ]; then
  say "  ✓ Uninstall bersih — tidak ada sisa."
else
  say "  ! $LEFT path masih ada, cek manual."
fi
hr
say "  Catatan: script/menu tunneling lama (menu, features/*) TIDAK disentuh."
hr
exit 0