# login-report

Tool mandiri untuk VPS tunneling (Ubuntu/Debian, Bash, Xray + OpenSSH/Dropbear).
Mengirim laporan user yang **aktif login** ke Telegram via systemd timer.

Terpisah total dari script tunneling: hanya baca (READ-ONLY) log Xray, config Xray,
dan db akun mytunnel. Tidak mengubah apa pun di sana.

## Format laporan

Satu pesan Telegram per protokol. Nama user Xray ditampilkan polos (tanpa suffix
`-vless` / `-trojan` / `@domain`).

```
IP     : 203.0.113.10
DOMAIN : contoh.domain.com
ISP    : DigitalOcean, LLC
Users Login SSH/Dropbear
pengguna 3 PID
Total : 3

Users Login VMESS
pengguna 12GB 1IP | 45
Total : 1

Users Login VLESS
...
Total : 0

Users Login TROJAN
pengguna 0GB 2IP | 389
Total : 1
```

Kolom pada baris Xray: `<nama> <usage GB> <jumlah>IP | <jumlah_koneksi>`.
Kolom setelah `|` (port / id / kuota) opsional, diatur lewat `INFO_COLUMNS`.

Hanya user yang:
1. login dalam window `XRAY_LOG_MINUTES` (default 15 menit), dan
2. terdaftar di db mytunnel (`/etc/mytunnel/db/<proto>.txt`) dengan status `active`.

## Instalasi

```bash
git clone https://github.com/Emans27/login-report.git
cd login-report
sudo bash install.sh
```

Setelah install:

```bash
lreport          # buka menu
# menu 1 → isi Bot Token + Chat ID
# menu 3 → aktifkan laporan
# menu 5 → kirim test
```

## Mengatur timer

### Lewat menu utama mytunnel (paling mudah)

Jalankan `menu`, lalu ketik **10** (LOGIN REPORT). Menu ini sudah terpasang otomatis
bila script tunneling yang kamu pakai sudah memuat login-report.

### Lewat perintah `lreport`

Cara paling mudah — lewat menu `lreport`:

| Menu | Fungsi |
|---|---|
| 2 | Interval: 5/10/15/30/60/180/360/720/1440 menit, atau jam harian (mis. 08:00) |
| 11 | Input manual: 1–1440 menit |
| 3 | Aktifkan / matikan laporan |
| 4 | Pilih protokol yang dikirim (SSH/VMESS/VLESS/TROJAN on-off) |
| 6 | Lihat status (interval, timer, konfigurasi aktif) |

Perubahan langsung berlaku, **tanpa reboot** (`daemon-reload` + restart timer).

Manual di shell:

```bash
# lihat jadwal saat ini
systemctl cat login-report.timer | grep OnCalendar
systemctl list-timers login-report.timer

# ubah jadwal langsung
sudo sed -i 's/^OnCalendar=.*/OnCalendar=*-*-* *:00\/15/' /etc/systemd/system/login-report.timer
sudo systemctl daemon-reload && sudo systemctl restart login-report.timer
```

Opsi `OnCalendar` yang dipakai:

| Config | OnCalendar |
|---|---|
| 5 menit | `*-*-* *:00/5` |
| 60 menit | `*-*-* *:00/60` |
| 1440 menit / 24 jam | `*-*-* 00:00:00` |
| Harian jam 08:00 | `*-*-* 08:00:00` |

## Konfigurasi

`/etc/login-report/config.conf` (chmod 600, root only):

```bash
BOT_TOKEN="<BOT_TOKEN>"
CHAT_ID="1234567890"

ENABLED="on"                # on | off
INTERVAL_MIN="30"           # 1-1440
DAILY_AT="08:00"            # isi kalau mau jadwal harian; kosongkan untuk interval
SEND_DELAY="1.5"            # jeda antar pesan (hindari rate limit Telegram)

XRAY_LOG_MINUTES="15"       # window "user aktif"
XRAY_ACCESS_LOG="/var/log/xray/access.log"
XRAY_CONFIG="/usr/local/etc/xray/config.json"
XRAY_API_ADDR="127.0.0.1:10085"

SEND_SSH="on"; SEND_VMESS="on"; SEND_VLESS="on"; SEND_TROJAN="on"
INFO_COLUMNS=""             #mis: "port id quota"
```

Token tidak pernah ditulis ke log. Di layar hanya ditampilkan sebagian:
token bot ditampilkan tersamar (mis. `<BOT_TOKEN>`).

## Uninstall

```bash
bash /opt/login-report/uninstall.sh
# atau: lreport → 7
```

Menghapus hanya file milik tool ini: `/opt/login-report/`, `/etc/login-report/`,
`/etc/systemd/system/login-report.{service,timer}`, `/usr/local/bin/lreport`,
`/var/log/login-report.log`. Tidak menyentuh script tunneling.

## Struktur

```
/opt/login-report/lib/common.sh     # config, log, util
/opt/login-report/lib/collector.sh  # kumpulkan data (SSH, Xray, db mytunnel)
/opt/login-report/lib/core.sh       # susun + kirim laporan, kelola timer
/opt/login-report/menu.sh           # menu lreport
/opt/login-report/uninstall.sh
/etc/login-report/config.conf
/var/log/login-report.log
/etc/systemd/system/login-report.service
/etc/systemd/system/login-report.timer
/usr/local/bin/lreport -> /opt/login-report/menu.sh
```

## Catatan

- Butuh `jq`, `curl`, GNU `awk` (fungsi `mktime`), systemd.
- Kolom usage GB diambil dari db mytunnel (`used_bytes`). Jika kolom tetap `0GB`,
  artinya cron `quota.sh` di script tunneling belum mengumpulkan trafik.
- PID = jumlah sesi SSH aktif per user (proses `sshd: <user>` anak, bukan `[priv]`).