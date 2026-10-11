#!/bin/bash
# login-report — collector (READ-ONLY terhadap milik tunneling lama)
# Format access.log Xray: "<ts> from <client_ip>:<port> accepted tcp:<dst> [<inboundTag> >> <outbound>] email: <email>"
# shellcheck disable=SC2034,SC2154,SC2317,SC2312

# ── identitas VPS ───────────────────────────────────────────
lr_public_ip(){
  local ip c="/tmp/.lr_pubip" age
  if [ -r "$c" ]; then age=$(( $(date +%s) - $(stat -c %Y "$c" 2>/dev/null || echo 0) ))
    [ "$age" -lt 300 ] && { cat "$c"; return; }; fi
  ip=$(curl -4 -fsS --max-time 6 https://api.ipify.org 2>/dev/null)
  [ -z "$ip" ] && ip=$(curl -4 -fsS --max-time 6 https://ifconfig.me 2>/dev/null)
  [ -z "$ip" ] && ip=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -1)
  [ -z "$ip" ] && ip="unknown"
  echo "$ip" > "$c" 2>/dev/null || true
  echo "$ip"
}

lr_domain(){
  local d f
  if [ "${DOMAIN:-auto}" != "auto" ] && [ -n "${DOMAIN:-}" ]; then echo "$DOMAIN"; return; fi
  for f in /etc/mytunnel/config/domain.txt /etc/xray/domain.txt; do
    [ -r "$f" ] || continue
    d=$(head -1c40 "$f" 2>/dev/null | tr -d '[:space:]')
    [ -n "$d" ] && { echo "$d"; return; }
  done
  for f in /root/.acme.sh/*.conf /etc/letsencrypt/renewal/*.conf; do
    [ -r "$f" ] || continue
    d=$(grep -m1 -E "^(Le_Domain|domains.?=)" "$f" 2>/dev/null | cut -d"'" -f2 | head -1 | tr -d '[:space:]')
    [ -z "$d" ] && d=$(grep -m1 -E "^(Le_Domain|aliases)" "$f" 2>/dev/null | tr -d '" ' | cut -d= -f2 | tr ',' '\n' | grep -v '^$' | head -1)
    [ -n "$d" ] && { echo "$d"; return; }
  done
  for f in /etc/mytunnel/cert/fullchain.crt /etc/letsencrypt/live/*/fullchain.pem; do
    [ -r "$f" ] || continue
    d=$(openssl x509 -in "$f" -noout -subject 2>/dev/null | sed -n 's/.*CN *= *//p' | tr -d '[:space:]')
    [ -n "$d" ] && { echo "$d"; return; }
  done
  echo "unknown"
}

lr_isp(){
  local ip="$1" c="/tmp/.lr_isp_$ip" age out
  if [ -r "$c" ]; then age=$(( $(date +%s) - $(stat -c %Y "$c" 2>/dev/null || echo 0) ))
    [ "$age" -lt 21600 ] && { cat "$c"; return; }; fi
  out=$(curl -4 -fsS --max-time 8 "http://ip-api.com/json/$ip?fields=isp,org,as" 2>/dev/null \
        | jq -r '.isp // .org // .as // empty' 2>/dev/null | head -1)
  [ -z "$out" ] && out="unknown"
  printf '%s' "$out" > "$c" 2>/dev/null || true
  echo "$out"
}

# ── SSH / Dropbear ──────────────────────────────────────────
# Hitung SESI (bukan proses): sshd "sshd: <user> [priv]" = 1 sesi (parent root),
# anak "sshd: <user>" (EUID=<user>) = 1 sesi juga. Dropbear: 1 proses = 1 sesi.
# Keluaran baris: "<user> <sesi>"
lr_ssh_rows(){
  local minuid sysusers line u
  minuid=$(awk '/^UID_MIN/{print $2}' /etc/login.defs 2>/dev/null); [ -z "$minuid" ] && minuid=1000
  # hanya akun yang terdaftar di db mytunnel → root@notty / user sistem tidak ikut
  # format ssh.txt: user|pass|expiry|limit_ip|status
  ps -eo user:32,args --no-headers 2>/dev/null | awk -v db="/etc/mytunnel/db/ssh.txt" '
    BEGIN{
      while((getline line < db)>0){
        if(line=="" || line ~ /^#/) continue
        n=split(line, f, "|")
        # status = kolom status terakhir (ssh.txt: user|pass|expiry|limit_ip|status)
        st = (n>=5 ? f[n] : "")
        if(f[1]=="" || st !~ /active/) continue
        known[f[1]]=1
      }
      close(db)
    }
    /sshd: / {
      u=""; priv=0
      for(i=1;i<=NF;i++) if($i=="sshd:"){ u=$(i+1); if($(i+2)=="[priv]") priv=1; break }
      if(!priv && u!="" && u!="root" && u!~/^\/usr\/sbin\/sshd$/ && (u in known)) cnt[u]++
      next
    }
    $0 ~ /dropbear/ { u=$1; if(u!="" && u!="root" && (u in known)) cnt[u]++ }
    END{ for(u in cnt) print u, cnt[u] }
  ' | sort -k1,1
}

lr_ssh_block(){
  local rows out="" total=0
  rows=$(lr_ssh_rows)
  out+=$'Users Login SSH/Dropbear\n'
  if [ -z "$rows" ]; then
    out+=$'(tidak ada user aktif)\n'
  else
    while read -r u c; do
      out+="$(printf '%s %s PID' "$u" "$c")"$'\n'
      total=$((total + c))
    done <<< "$rows"
  fi
  out+=$(printf 'Total : %s\n' "$total")
  printf '<pre>%s</pre>' "${out%$'\n'}"
}

# ── Xray: user per protokol dari config.json (READ-ONLY) ────
# keluarkan: "<PROTO>|<email>|<tag>|<id>"
lr_xray_config_rows(){
  [ -r "$XRAY_CONFIG" ] || return 0
  jq -r '
    .inbounds[]?
    | select(.settings.clients != null)
    | . as $ib
    | ($ib.protocol // "" | ascii_upcase) as $proto
    | $ib.settings.clients[]
    | select(.email != null and .email != "")
    | "\($proto)|\(.email)|\($ib.tag)|\(.id // "-")"
  ' "$XRAY_CONFIG" 2>/dev/null
}

# ── Xray: log dalam window N menit ──────────────────────────
# keluarkan baris normal: "<ts> <client_ip> <proto> <email> <tag>"
lr_xray_log_rows(){
  local minutes="${1:-15}" root="${XRAY_ACCESS_LOG}"
  [ -r "$root" ] || return 0
  # cutoff epoch dihitung sekali di bash; awk bandingkan angka, tanpa fork date per baris
  local cutoff
  cutoff=$(date +%s); cutoff=$(( cutoff - minutes*60 ))

  local files=("$root")
  [ -r "${root}.1" ] && files+=("${root}.1")
  [ -r "${root}.2.gz" ] && files+=("${root}.2.gz")

  # log Xray pakai waktu LOKAL (TZ VPS); mktime() GNU awk mengembalikan epoch UTC dari
  # waktu lokal sehingga langsung bisa dibandingkan dengan cutoff `date +%s` (UTC).
  cat "${files[@]}" 2>/dev/null | awk -v cut="$cutoff" '
    /accepted/ && /email:/ {
      if (match($1, /^[0-9]{4}\/[0-9]{2}\/[0-9]{2}$/) && match($2, /^[0-9]{2}:[0-9]{2}:[0-9]{2}/)) {
        split($1, A, "/"); split($2, B, ":")
        sec = mktime(A[1]" "A[2]" "A[3]" "B[1]" "B[2]" "int(B[3]))
        if (sec>0 && sec<cut) next
      }
      ip="?"; for(i=1;i<=NF;i++){ if($i=="from"){ split($(i+1),b,":"); ip=b[1]; break } }
      email=""; for(i=1;i<=NF;i++){ if($i=="email:"){ email=$(i+1); break } }
      tag="?"; for(i=1;i<=NF;i++){ if($i ~ /^\[/) { tag=$i; gsub(/^\[|\]$/,"",tag); sub(/ *>>.*/,"",tag); break } }
      proto="?"; if(tag ~ /^vlnui|^vless/) proto="VLESS"
      split(tag,t,"-"); p=t[1]
      if (p=="vmess") proto="VMESS"; else if (p=="vless") proto="VLESS"; else if (p=="trojan") proto="TROJAN"
      print ip, proto, email, tag
    }'
}

# ── Xray: Stats API (per-inbound, karena stats per-user ─────
# Butuh policy.system.statsInboundUplink/Downlink = true (cek, jangan ubah)
lr_xray_stats_ready(){
  command -v xray >/dev/null 2>&1 || return 1
  command -v jq  >/dev/null 2>&1 || return 1
  [ -r "$XRAY_CONFIG" ] || return 1
  local up
  up=$(jq -r '.policy.system.statsInboundUplink // false' "$XRAY_CONFIG" 2>/dev/null)
  [ "$up" = "true" ] || return 1
  return 0
}

lr_stat_bytes(){
  local name="$1" bin out
  bin=$(command -v xray)
  out=$(timeout 8 "$bin" api statsquery --server="$XRAY_API_ADDR" -pattern="inbound>>>$name" 2>/dev/null \
        | jq -r --arg k "inbound>>>$name" '.stat[]? | select(.name==$k) | .value // empty' 2>/dev/null | head -1)
  echo "${out:-0}"
}

# total bytes (rx+tx) sebuah inbound tag
lr_inbound_bytes(){
  local tag="$1" rx tx
  rx=$(lr_stat_bytes "$tag>>>traffic>>>downlink")
  tx=$(lr_stat_bytes "$tag>>>traffic>>>uplink")
  echo $(( ${rx:-0} + ${tx:-0} ))
}

lr_fmt_gb(){
  awk -v b="${1:-0}" 'BEGIN{ if(b<=0){print "-"; exit} printf "%.2f", b/1073741824 }'
}
# usage bulat integer gaya bot lama: 30GB
lr_fmt_gb_int(){
  awk -v b="${1:-0}" 'BEGIN{ if(b<=0){print "0"; exit} printf "%d", (b/1073741824)+0.5 }'
}

# ── db mytunnel (READ-ONLY): user|id|expiry|limit_ip|quota|used_bytes|status
# db memakai nama bebas ("sunek"); email Xray = "<nama>-<proto>@tunnel" → normalkan suffix
lr_db_file(){ printf '/etc/mytunnel/db/%s.txt' "$(printf '%s' "${1,,}")"; }
lr_db_norm_user(){
  # buang "-vless/-trojan/-vmess" dan "@domain" supaya cocok dengan key db
  local u="${1%%@*}"
  printf '%s' "$u" | sed -E 's/-?(vmess|vless|trojan)$//'
}
lr_db_used_bytes(){
  local f v u; f=$(lr_db_file "$1"); [ -r "$f" ] || { echo 0; return; }
  u=$(lr_db_norm_user "$2")
  v=$(awk -F'|' -v u="$u" '$1==u{print $6}' "$f" 2>/dev/null | head -1 | tr -dc '0-9')
  case "$v" in "") echo 0;; *) echo "$v";; esac
}
lr_db_quota(){
  local f v u; f=$(lr_db_file "$1"); [ -r "$f" ] || { echo "-"; return; }
  u=$(lr_db_norm_user "$2")
  v=$(awk -F'|' -v u="$u" '$1==u{print $5}' "$f" 2>/dev/null | head -1 | tr -dc '0-9')
  case "$v" in ""|0) echo "Unlimited";; *) echo "${v}GB";; esac
}
lr_db_limit_ip(){
  local f v u; f=$(lr_db_file "$1"); [ -r "$f" ] || { echo "-"; return; }
  u=$(lr_db_norm_user "$2")
  v=$(awk -F'|' -v u="$u" '$1==u{print $4}' "$f" 2>/dev/null | head -1 | tr -dc '0-9')
  case "$v" in ""|0) echo "-";; *) echo "$v";; esac
}

# ── Xray: blok per protokol ─────────────────────────────────
# keluarkan <pre> blok untuk satu protokol (VMESS|VLESS|TROJAN)
lr_xray_block(){
  local proto="$1"
  local total=0 body email tag idx active_ips line sorted out_html=""
  local logrows
  logrows=$(lr_xray_log_rows "$XRAY_LOG_MINUTES")

  # daftar user & tag dari config Xray (dipakai untuk memetakan email → tag inbound)
  local -A cfg=()
  while IFS='|' read -r p e t i; do
    [ "$p" = "$proto" ] && [ -n "$e" ] && cfg["$e"]="$t|$i"
  done < <(lr_xray_config_rows)

  # gabung email dari log — HANYA user yang aktif dalam window (sesuai spesifikasi:
  # "hanya tampilkan user yang aktif saat ini") DAN terdaftar di db mytunnel
  local -A all=() tagof=()
  local e pfx udb
  pfx="/etc/mytunnel/db/${proto,,}.txt"
  udb=$(awk -F'|' '!/^#/ && NF>=7 && $7 ~ /active/ {print $1}' "$pfx" 2>/dev/null | sort -u)
  local -A known=()
  while read -r k; do [ -n "$k" ] && known["$k"]=1; done <<< "$udb"

  while read -r ip p e t; do
    [ "$p" = "$proto" ] || continue
    [ -n "$e" ] && e="${e%%@*}"  # buang domain @tunnel
    [ -z "$e" ] && continue
    # cocokkan ke db: "sunek-vless" atau "sunek"
    [ -z "${known[$e]+x}" ] && [ -z "${known[$(lr_db_norm_user "$e")]+x}" ] && continue
    [ -z "${all[$e]+x}" ] && { all[$e]=1; tagof[$e]="${t:-?}|-"; }
  done <<< "$logrows"

  # hitung IP unik per email (filter sama: hanya user db mytunnel yang aktif)
  local -A uniqip=()
  while read -r ip p e t; do
    [ "$p" = "$proto" ] || continue
    [ -n "$e" ] && e="${e%%@*}"
    [ -z "$e" ] && continue
    [ -z "${all[$e]+x}" ] && continue
    [ "$ip" != "?" ] && [ -n "$ip" ] && uniqip["$e"]+="$ip "
  done <<< "$logrows"

  # urut abjad
  sorted=$(printf '%s\n' "${!all[@]}" | sort -f)
  body+=$'Users Login '"$proto"$'\n'
  if [ -z "$sorted" ]; then
    body+=$'(tidak ada user aktif)\n'
  else
    while read -r e; do
      [ -z "$e" ] && continue
      IFS='|' read -r tag idx <<< "${tagof[$e]:-?|-}"
      # tampil: nama saja (buang "-vless/-trojan/-vmess" dan "@domain")
      local disp usage cnt info base
      disp=$(printf '%s' "$e" | cut -d@ -f1 | sed -E 's/-?(vmess|vless|trojan)$//')
      # usage dari db mytunnel (sumber kebenaran yang dipakai script lama)
      local used_b; used_b=$(lr_db_used_bytes "$proto" "$e")
      usage="${used_b}GB"
      [ "$used_b" = "0" ] && usage="0GB"
      cnt=$(printf '%s' "$logrows" | awk -v P="$proto" -v E="$e" '$2==P && $3 ~ E' | wc -l)
      [ "$cnt" -eq 0 ] && cnt=1
      # IP unik
      local ips; ips=$(printf '%s' "${uniqip[$e]:-}" | tr ' ' '\n' | grep -v '^$' | sort -u | wc -l)
      [ "$ips" -eq 0 ] && ips=1
      # kolom info opsional (port|id|quota) setelah "|"
      base="${ips}IP | ${cnt}"
      local extra; extra=$(lr_extra_info "$tag" "$e")
      [ -n "$extra" ] && base="$base | $extra"
      body+="$(printf '%s %s %s' "$disp" "$usage" "$base")"$'\n'
      total=$((total+1))
    done <<< "$sorted"
  fi
  body+=$(printf 'Total : %s\n' "$total")
  printf '<pre>%s</pre>' "${body%$'\n'}"
}

# kolom info opsional: port | id | quota
lr_extra_info(){
  local tag="$1" email="$2" parts=() p IFS=','
  [ -z "${INFO_COLUMNS:-}" ] && return 0
  for p in $INFO_COLUMNS; do
    p=$(echo "$p" | tr -d ' ')
    case "$p" in
      port) parts+=("port $(lr_inbound_port "$tag")") ;;
      id)   parts+=("$(lr_user_id "$email")") ;;
      quota) parts+=("kuota $(lr_user_quota "$email")") ;;
    esac
  done
  [ "${#parts[@]}" -gt 0 ] && echo "${parts[*]}"
}

lr_inbound_port(){
  jq -r --arg t "$1" '.inbounds[]? | select(.tag==$t) | .port // "-"' "$XRAY_CONFIG" 2>/dev/null | head -1
}
lr_user_id(){
  jq -r --arg e "$1" '.inbounds[]? | select(.settings.clients) | .settings.clients[] | select(.email==$e) | .id // "-"' \
    "$XRAY_CONFIG" 2>/dev/null | head -1
}
lr_user_quota(){
  local e="$1" f v
  for f in /etc/mytunnel/db/quota.db /etc/mytunnel/db/xray_quota.db /etc/mytunnel/xray/quota.txt; do
    [ -r "$f" ] || continue
    v=$(grep -m1 -F "$e" "$f" 2>/dev/null | awk -F'[:=]' '{print $2}' | tr -d ' ')
    [ -n "$v" ] && { echo "$v"; return; }
  done
  echo "-"
}