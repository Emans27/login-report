#!/usr/bin/env bash
# tampilkan tiap pesan laporan terpisah (verifikasi format)
. /etc/login-report/config.conf
. /opt/login-report/lib/common.sh
. /opt/login-report/lib/collector.sh
. /opt/login-report/lib/core.sh
lr_load_conf >/dev/null 2>&1
lr_build_messages > /tmp/lr_msgs.txt 2>/dev/null
rm -f /tmp/lr_msg_*.txt
awk '{ sub(/^__LR_MSG_END__$/,""); if($0=="__LR_MSG_END__"){n++;next} print > sprintf("/tmp/lr_msg_%d.txt",n) }' /tmp/lr_msgs.txt
for f in /tmp/lr_msg_*.txt; do
  echo "===== $f ====="
  sed 's/</\&lt;/g' "$f"
done
