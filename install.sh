#!/bin/bash
# login-report installer — pasang tool mandiri (TIDAK menyentuh script tunneling lain)
# shellcheck disable=SC1091,SC2034
set -euo pipefail
LR_VERSION="1.0.0"
LR_BASE=/opt/login-report
LR_ETC=/etc/login-report
SRC="$(cd "$(dirname "$0")" && pwd)"

say(){ printf '%s\n' "$*"; }
ok(){  printf '[+] %s\n' "$*"; }
hr(){  printf '%s\n' "════════════════════════════════════════"; }

if [ "$(id -u)" -ne 0 ]; then say "ERROR: harus root"; exit 1; fi

hr; say "  login-report installer v$LR_VERSION  —  tool mandiri, SUNEK VPN"; hr

# ── 1. dependensi ───────────────────────────────────────────
say "▸ Cek dependensi (jq, curl, procps, systemd)..."
missing=0
for c in jq curl ps awk stat; do
  command -v "$c" >/dev/null 2>&1 || { say "  kurang: $c"; missing=1; }
done
if [ "$missing" -eq 1 ]; then
  say "  Install dependensi..."
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq 2>/dev/null | tail -1 || true
  apt-get install -y -qq jq curl procps 2>/dev/null | tail -2 || true
fi
for c in jq curl ps; do command -v "$c" >/dev/null 2>&1 || say "  PERINGATAN: $c tidak tersedia"; done
ok "Dependensi OK"

# ── 2. struktur folder ──────────────────────────────────────
say "▸ Buat struktur folder..."
install -d -m 755 "$LR_BASE" "$LR_ETC"
install -d -m 755 "$LR_BASE/lib"
install -d -m 700 "$LR_ETC"
ok "Folder dibuat: $LR_BASE, $LR_ETC"

# ── 3. pasang kode ──────────────────────────────────────────
say "▸ Pasang kode..."
install -m 644 "$SRC/lib/common.sh"    "$LR_BASE/lib/common.sh"
install -m 644 "$SRC/lib/collector.sh" "$LR_BASE/lib/collector.sh"
install -m 755 "$SRC/lib/core.sh"      "$LR_BASE/lib/core.sh"
install -m 755 "$SRC/menu.sh"          "$LR_BASE/menu.sh"
install -m 755 "$SRC/uninstall.sh"     "$LR_BASE/uninstall.sh"
ln -sf "$LR_BASE/menu.sh" /usr/local/bin/lreport
ok "Kode terpasang + perintah 'lreport' aktif"

# ── 4. config default (tidak overwrite kalau sudah ada) ─────
say "▸ Config..."
if [ ! -f "$LR_ETC/config.conf" ]; then
  # salin default, sesuaikan path dengan deteksi VPS ini
  access=/var/log/xray/access.log; xcfg=/usr/local/etc/xray/config.json; api=127.0.0.1:10085
  [ -f /etc/xray/config.json ] && xcfg=/etc/xray/config.json
  [ -f /var/log/xray/access.log ] || access=/var/log/xray/access.log
  sed -e "s#^XRAY_ACCESS_LOG=.*#XRAY_ACCESS_LOG=$access#" \
      -e "s#^XRAY_CONFIG=.*#XRAY_CONFIG=$xcfg#" \
      -e "s#^XRAY_API_ADDR=.*#XRAY_API_ADDR=$api#" \
      "$SRC/config.conf" > "$LR_ETC/config.conf"
  chmod 600 "$LR_ETC/config.conf"
  ok "Config dibuat: $LR_ETC/config.conf (chmod 600)"
else
  ok "Config sudah ada, tidak diubah"
fi

# ── 5. log file ─────────────────────────────────────────────
touch /var/log/login-report.log && chmod 640 /var/log/login-report.log
ok "Log: /var/log/login-report.log"

# ── 6. systemd unit ─────────────────────────────────────────
say "▸ Pasang systemd service + timer..."
cat > /etc/systemd/system/login-report.service <<EOF
[Unit]
Description=login-report — kirim laporan login ke Telegram
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=$LR_BASE/lib/core.sh
User=root
StandardOutput=journal
StandardError=journal
# token hanya dari config 600 root-only
EOF

cat > /etc/systemd/system/login-report.timer <<EOF
[Unit]
Description=login-report timer (default 30 menit)
Documentation=man:systemd.timer(5)

[Timer]
OnCalendar=*-*-* *:00/30
Persistent=true
AccuracySec=1min
Unit=login-report.service

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
# aktifkan timer TIDAK otomatis — user aktifkan via menu (3)
ok "Unit terpasang: login-report.service, login-report.timer"

# ── 7. selanjutnya ──────────────────────────────────────────
hr
ok "INSTALASI SELESAI"
say ""
say "  Langkah berikutnya:"
say "    1. Ketik  lreport   (buka menu)"
say "    2. Menu 1 → isi Bot Token + Chat ID"
say "    3. Menu 3 → aktifkan laporan"
say "    4. Menu 5 → kirim test"
say ""
say "  Catatan:"
say "    - Config: $LR_ETC/config.conf (600, root only)"
say "    - Log   : /var/log/login-report.log"
say "    - Tool TIDAK menyentuh script/menu tunneling lama (read-only)."
say "    - Uninstall: ketik 'lreport' → 7, atau bash $LR_BASE/uninstall.sh"
hr
exit 0