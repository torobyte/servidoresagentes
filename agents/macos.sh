#!/bin/sh
# Torobyte Monitor Cloud - macOS agent
# Compatible: macOS 10.12 (Sierra) y superiores - Intel y Apple Silicon
#
# Instalación (Terminal con sudo):
#   curl -fsSL 'https://<host>/api/public/agents/macos.sh' \
#     | sudo TOKEN='xxx' URL='https://<host>/api/public/ingest/metrics' sh -s install
#
# El script se autoinstala como LaunchDaemon (com.torobyte.agent) ejecutándose
# como root al inicio del sistema, y vuelve a ejecutarse cada INTERVAL segundos.
set -u

AGENT_TOKEN="${AGENT_TOKEN:-${TOKEN:-}}"
INGEST_URL="${INGEST_URL:-${URL:-}}"
INTERVAL="${INTERVAL:-300}"
ONCE="${ONCE:-0}"
AGENT_VERSION="1.5.0-macos"
MODE="${1:-run}"

INSTALL_DIR="/usr/local/torobyte-agent"
AGENT_SCRIPT="$INSTALL_DIR/torobyte-agent.sh"
PLIST_PATH="/Library/LaunchDaemons/com.torobyte.agent.plist"
LOG_PATH="/var/log/torobyte-agent.log"
LABEL="com.torobyte.agent"

step() { printf "\033[1;36m[%s/%s]\033[0m %s\n" "$1" "$2" "$3"; }
ok()   { printf "      \033[1;32m✓\033[0m %s\n" "$1"; }
fail() { printf "      \033[1;31m✗\033[0m %s\n" "$1" >&2; exit 1; }

if [ "$MODE" = "install" ] || [ "$MODE" = "install-service" ]; then
  TOTAL=7
  printf "\n\033[1m🛠  Torobyte Monitor Agent — Instalación %s\033[0m\n\n" "$AGENT_VERSION"

  step 1 $TOTAL "Validando parámetros..."
  [ -n "$AGENT_TOKEN" ] || fail "AGENT_TOKEN (o TOKEN) requerido"
  [ -n "$INGEST_URL" ] || fail "INGEST_URL (o URL) requerido"
  ok "token=${AGENT_TOKEN%${AGENT_TOKEN#????????}}…  url=$INGEST_URL"

  step 2 $TOTAL "Verificando privilegios (sudo/root)..."
  [ "$(id -u)" = "0" ] || fail "se requiere sudo/root para instalar el LaunchDaemon"
  ok "OK"

  step 3 $TOTAL "Creando carpeta de instalación: $INSTALL_DIR"
  mkdir -p "$INSTALL_DIR" || fail "no se pudo crear $INSTALL_DIR"
  ok "OK"

  step 4 $TOTAL "Descargando agente..."
  AGENT_SCRIPT_URL="${AGENT_SCRIPT_URL:-$(printf '%s' "$INGEST_URL" | sed 's|/api/public/ingest/metrics.*|/api/public/agents/macos.sh|')}"
  curl -fsSL "$AGENT_SCRIPT_URL" -o "$AGENT_SCRIPT" || fail "no se pudo descargar $AGENT_SCRIPT_URL"
  chmod +x "$AGENT_SCRIPT"
  ok "$(wc -c <"$AGENT_SCRIPT" | tr -d ' ') bytes"

  step 5 $TOTAL "Enviando primera métrica de prueba..."
  if AGENT_TOKEN="$AGENT_TOKEN" INGEST_URL="$INGEST_URL" ONCE=1 /bin/sh "$AGENT_SCRIPT" >/tmp/torobyte-first.log 2>&1; then
    ok "OK — el servidor pasará a 'en línea'"
  else
    cat /tmp/torobyte-first.log >&2
    fail "no se pudo enviar la primera métrica (revisa token/URL/firewall)"
  fi

  step 6 $TOTAL "Registrando LaunchDaemon ($LABEL)..."
  launchctl bootout system "$PLIST_PATH" >/dev/null 2>&1 || true
  launchctl unload "$PLIST_PATH" >/dev/null 2>&1 || true
  cat >"$PLIST_PATH" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/sh</string>
    <string>$AGENT_SCRIPT</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>AGENT_TOKEN</key><string>$AGENT_TOKEN</string>
    <key>INGEST_URL</key><string>$INGEST_URL</string>
    <key>INTERVAL</key><string>$INTERVAL</string>
    <key>PATH</key><string>/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
  </dict>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>$LOG_PATH</string>
  <key>StandardErrorPath</key><string>$LOG_PATH</string>
</dict>
</plist>
EOF
  chown root:wheel "$PLIST_PATH"
  chmod 644 "$PLIST_PATH"
  if launchctl bootstrap system "$PLIST_PATH" >/dev/null 2>&1; then
    ok "LaunchDaemon cargado (bootstrap)"
  else
    launchctl load -w "$PLIST_PATH" >/dev/null 2>&1 || fail "no se pudo cargar el LaunchDaemon"
    ok "LaunchDaemon cargado (load)"
  fi

  step 7 $TOTAL "Verificando estado..."
  sleep 2
  if launchctl list 2>/dev/null | grep -q "$LABEL"; then
    ok "agente en ejecución"
  else
    tail -n 20 "$LOG_PATH" 2>/dev/null >&2 || true
    fail "el LaunchDaemon no quedó activo"
  fi

  printf "\n\033[1;32m✔ Instalación completada\033[0m\n"
  printf "  script: %s\n" "$AGENT_SCRIPT"
  printf "  log:    %s\n" "$LOG_PATH"
  printf "  daemon: %s\n\n" "$LABEL"
  exit 0
fi

if [ "$MODE" = "uninstall" ] || [ "$MODE" = "remove" ]; then
  printf "\n\033[1m🗑  Torobyte Monitor Agent — Desinstalación\033[0m\n\n"
  [ "$(id -u)" = "0" ] || fail "se requiere sudo/root para desinstalar el LaunchDaemon"
  launchctl bootout system "$PLIST_PATH" >/dev/null 2>&1 || true
  launchctl unload "$PLIST_PATH" >/dev/null 2>&1 || true
  rm -f "$PLIST_PATH"
  ok "LaunchDaemon eliminado ($LABEL)"
  pkill -f "$AGENT_SCRIPT" 2>/dev/null || true
  rm -rf "$INSTALL_DIR"
  rm -f "$LOG_PATH" /tmp/torobyte-first.log /tmp/torobyte-agent.*.resp
  ok "archivos eliminados"
  printf "\n\033[1;32m✔ Agente desinstalado del host\033[0m\n"
  printf "   Recuerda eliminar el servidor también desde la plataforma si ya no lo necesitas.\n\n"
  exit 0
fi

# -------------------------- Runtime (collect/post) --------------------------

RESP_FILE="${TMPDIR:-/tmp}/torobyte-agent.$$.resp"
case "$INTERVAL" in ''|*[!0-9]*) INTERVAL=300 ;; esac
[ "$INTERVAL" -lt 10 ] && INTERVAL=10

if [ -z "$AGENT_TOKEN" ] || [ -z "$INGEST_URL" ]; then
  echo "AGENT_TOKEN and INGEST_URL are required" >&2; exit 1
fi
command -v curl >/dev/null 2>&1 || { echo "curl is required" >&2; exit 1; }

json_escape() {
  printf '%s' "${1:-}" | tr '\n' ' ' | awk 'BEGIN{ORS=""}{gsub(/\\/,"\\\\"); gsub(/"/,"\\\""); gsub(/\r/,"\\r"); gsub(/\t/,"\\t"); print}'
}
safe_number() { awk -v v="${1:-0}" 'BEGIN{if (v ~ /^-?[0-9]+([.][0-9]+)?$/) printf "%s", v+0; else printf "0"}'; }
safe_int()    { awk -v v="${1:-0}" 'BEGIN{if (v ~ /^[0-9]+$/) printf "%d", v; else printf "0"}'; }
now_iso()     { date -u +"%Y-%m-%dT%H:%M:%SZ"; }

private_ip() {
  for i in en0 en1 en2 en3 en4 en5 en6 en7 en8; do
    ip=$(ipconfig getifaddr "$i" 2>/dev/null)
    [ -n "$ip" ] && { printf '%s' "$ip"; return; }
  done
  ifconfig 2>/dev/null | awk '/inet / && $2 != "127.0.0.1" {print $2; exit}'
}

public_ip() {
  for url in https://api.ipify.org https://ifconfig.me/ip https://icanhazip.com https://checkip.amazonaws.com; do
    ip=$(curl -fsS --connect-timeout 3 --max-time 6 "$url" 2>/dev/null | tr -d '\n\r ')
    case "$ip" in
      *[!0-9.]*) ;;
      ?*.?*.?*.?*) printf '%s' "$ip"; return ;;
    esac
  done
}

cpu_usage() {
  # top -l 2 to skip the first (cumulative) sample. En Apple Silicon -s 1 puede ser lento,
  # usamos -s 0 (mínimo posible) y limitamos campos con -stats para acelerar.
  top -l 2 -n 0 -s 0 -stats cpu 2>/dev/null | awk '/CPU usage/ {l=$0} END{
    if (l=="") {print 0; exit}
    n=split(l,a,",")
    for(i=1;i<=n;i++) if (a[i] ~ /idle/) { gsub(/[^0-9.]/,"",a[i]); idle=a[i]+0 }
    if (idle=="") {print 0; exit}
    printf "%.1f", 100-idle
  }'
}

ram_usage() {
  page=$(sysctl -n hw.pagesize 2>/dev/null); [ -n "$page" ] || page=4096
  total=$(sysctl -n hw.memsize 2>/dev/null); [ -n "$total" ] || total=0
  vm_stat 2>/dev/null | awk -v page="$page" -v total="$total" '
    /Pages active/                  {act=$3+0}
    /Pages wired down/              {wir=$4+0}
    /Pages occupied by compressor/  {cmp=$5+0}
    END{
      if (total<=0) {print 0; exit}
      used=(act+wir+cmp)*page
      printf "%.1f", used*100/total
    }'
}

total_ram() {
  bytes=$(sysctl -n hw.memsize 2>/dev/null)
  awk -v b="${bytes:-0}" 'BEGIN{ if(b<=0){print "0 GB"; exit} g=b/1024/1024/1024; printf "%.1f GB", g }'
}

disk_root() {
  df -k / 2>/dev/null | awk 'NR==2 {gsub("%","",$5); print $5+0}'
}
total_disk() {
  df -k / 2>/dev/null | awk 'NR==2 {kb=$2; gb=kb/1024/1024; if(gb>=1024) printf "%.2f TB", gb/1024; else printf "%.1f GB", gb}'
}

uptime_human() {
  bt=$(sysctl -n kern.boottime 2>/dev/null | sed -n 's/.*sec = \([0-9]*\).*/\1/p')
  [ -n "$bt" ] || { uptime | sed 's/.*up //;s/,.*users.*//'; return; }
  now=$(date +%s); s=$((now-bt))
  d=$((s/86400)); h=$(((s%86400)/3600)); m=$(((s%3600)/60))
  if [ $d -gt 0 ]; then printf "%dd %dh %dm" $d $h $m
  elif [ $h -gt 0 ]; then printf "%dh %dm" $h $m
  else printf "%dm" $m; fi
}

load_avg() {
  l=$(sysctl -n vm.loadavg 2>/dev/null | tr -d '{}')
  echo "$l" | awk '{printf "%s %s %s", ($1==""?"0":$1), ($2==""?"0":$2), ($3==""?"0":$3)}'
}

# Network: delta de bytes en/out (excluyendo lo0) usando netstat -ibn
NET_STATE="${TMPDIR:-/tmp}/torobyte-net.state"
net_io() {
  cur_rx=0; cur_tx=0
  while IFS= read -r line; do
    set -- $line
    iface=$1
    case "$iface" in lo0|gif*|stf*|utun*|awdl*|llw*) continue ;; esac
    # netstat -ibn: Name Mtu Network Address Ipkts Ierrs Ibytes Opkts Oerrs Obytes Coll
    [ -n "${7:-}" ] || continue
    cur_rx=$((cur_rx + ${7:-0}))
    cur_tx=$((cur_tx + ${10:-0}))
  done <<EOF
$(netstat -ibn 2>/dev/null | awk 'NR>1 && $1!=prev {print; prev=$1}')
EOF
  now=$(date +%s)
  if [ -f "$NET_STATE" ]; then
    . "$NET_STATE" 2>/dev/null || true
    last_t=${LAST_T:-0}; last_rx=${LAST_RX:-0}; last_tx=${LAST_TX:-0}
  else
    last_t=0; last_rx=0; last_tx=0
  fi
  printf 'LAST_T=%s\nLAST_RX=%s\nLAST_TX=%s\n' "$now" "$cur_rx" "$cur_tx" >"$NET_STATE"
  dt=$((now - last_t))
  [ $dt -le 0 ] && dt=1
  awk -v a="$last_rx" -v b="$cur_rx" -v c="$last_tx" -v d="$cur_tx" -v dt="$dt" \
    'BEGIN{ rx=(b-a)/dt; tx=(d-c)/dt; if(rx<0)rx=0; if(tx<0)tx=0; printf "%.2f %.2f", rx/1024/1024, tx/1024/1024 }'
}

collect() {
  hostname_v=$(hostname 2>/dev/null || uname -n)
  kernel=$(uname -r 2>/dev/null)
  arch=$(uname -m 2>/dev/null)
  cores=$(safe_int "$(sysctl -n hw.logicalcpu 2>/dev/null)"); [ "$cores" -gt 0 ] || cores=1
  cpu_model=$(sysctl -n machdep.cpu.brand_string 2>/dev/null)
  [ -n "$cpu_model" ] || cpu_model="Apple Silicon"
  prod=$(sw_vers -productName 2>/dev/null); ver=$(sw_vers -productVersion 2>/dev/null)
  os_name="${prod:-macOS} ${ver:-}"
  tram=$(total_ram); priv=$(private_ip); pub=$(public_ip); up=$(uptime_human)
  cpu=$(safe_number "$(cpu_usage)")
  ram=$(safe_number "$(ram_usage)")
  disk=$(safe_number "$(disk_root)")
  tdisk=$(total_disk); [ -n "$tdisk" ] || tdisk="0 GB"
  set -- $(load_avg); l1=$(safe_number "$1"); l5=$(safe_number "$2"); l15=$(safe_number "$3")
  set -- $(net_io); net_in=$(safe_number "$1"); net_out=$(safe_number "$2")
  cpu_cores_arr=$(awk -v c="$cores" -v t="$cpu" 'BEGIN{printf "["; for(i=0;i<c;i++){ if(i>0) printf ","; printf "%.1f", t} printf "]"}')

  gpu=$(system_profiler SPDisplaysDataType 2>/dev/null | awk -F': ' '/Chipset Model/{print $2; exit}')
  [ -n "$gpu" ] || gpu="GPU desconocida"
  motherboard=$(sysctl -n hw.model 2>/dev/null)
  [ -n "$motherboard" ] || motherboard="Apple"
  mac_addr=$(ifconfig 2>/dev/null | awk '/^[a-z]/{iface=$1; sub(":","",iface)} /ether/{if(iface!="lo0") printf "%s%s=%s", (n++?",":""), iface, $2}')

  latency_ms=$(ping -c 1 -W 1000 1.1.1.1 2>/dev/null | awk -F'time=' '/time=/{split($2,t," "); printf "%d", t[1]+0.5; exit}')
  case "$latency_ms" in ''|*[!0-9]*) latency_ms=0 ;; esac

  cat <<EOF
{"hostname":"$(json_escape "$hostname_v")","os":"$(json_escape "$os_name")","kernel":"$(json_escape "$kernel")","arch":"$(json_escape "$arch")","cores":$cores,"cpu_model":"$(json_escape "$cpu_model")","total_ram":"$(json_escape "$tram")","total_disk":"$(json_escape "$tdisk")","public_ip":"$(json_escape "$pub")","private_ip":"$(json_escape "$priv")","uptime":"$(json_escape "$up")","cpu":$cpu,"cpu_cores":$cpu_cores_arr,"ram":$ram,"disk":$disk,"network_in":$net_in,"network_out":$net_out,"load_avg":{"1":$l1,"5":$l5,"15":$l15},"gpu":"$(json_escape "$gpu")","motherboard":"$(json_escape "$motherboard")","mac_address":"$(json_escape "$mac_addr")","latency_ms":$latency_ms,"agent_version":"$AGENT_VERSION"}
EOF
}

collect_processes() {
  ps -axo pid=,user=,pcpu=,pmem=,rss=,comm=,command= -r 2>/dev/null | head -n 25 | awk '
    BEGIN{printf "["; first=1}
    {
      pid=$1; user=$2; cpu=$3; mem=$4; rss=$5; name=$6;
      cmd=""; for(i=7;i<=NF;i++){cmd=cmd (i==7?"":" ") $i}
      gsub(/\\/,"\\\\",cmd); gsub(/"/,"\\\"",cmd);
      gsub(/\\/,"\\\\",name); gsub(/"/,"\\\"",name);
      gsub(/\\/,"\\\\",user); gsub(/"/,"\\\"",user);
      mem_mb=rss/1024;
      if(!first) printf ","; first=0;
      printf "{\"pid\":%d,\"user\":\"%s\",\"name\":\"%s\",\"cpu\":%s,\"mem\":%s,\"mem_mb\":%.1f,\"command\":\"%s\"}", pid,user,name,cpu,mem,mem_mb,substr(cmd,1,400)
    }
    END{printf "]"}'
}

collect_ports() {
  # En Apple Silicon (macOS 12+) 'lsof -iUDP' puede tardar minutos. Sólo TCP LISTEN.
  if command -v lsof >/dev/null 2>&1; then
    lsof -nP -iTCP -sTCP:LISTEN 2>/dev/null | awk 'NR>1{print "TCP",$1,$2,$9}' | awk '
      BEGIN{printf "["; first=1}
      {
        proto=$1; pname=$2; pid=$3; addr=$4
        n=split(addr,a,":"); port=a[n]; sub(":"port"$","",addr);
        if(port+0<=0)next;
        gsub(/\\/,"\\\\",pname); gsub(/"/,"\\\"",pname);
        gsub(/\\/,"\\\\",addr); gsub(/"/,"\\\"",addr);
        if(!first)printf ","; first=0;
        printf "{\"protocol\":\"%s\",\"port\":%d,\"address\":\"%s\",\"process\":\"%s\",\"pid\":%s}", proto,port,addr,pname,(pid~/^[0-9]+$/?pid:"null")
      }
      END{printf "]"}'
  else
    printf "[]"
  fi
}

collect_disks() {
  df -k 2>/dev/null | awk '
    BEGIN{printf "["; first=0}
    NR==1{next}
    {
      device=$1; total=$2*1024; used=$3*1024; free=$4*1024; pct=$5; gsub("%","",pct); mp=$9
      for(i=10;i<=NF;i++) mp=mp" "$i
      if (total<=0) next
      if (device ~ /^(devfs|map |fdesc$)/) next
      if (mp ~ /^\/System\/Volumes\/(VM|Preboot|Update|xarts|iSCPreboot|Hardware|Recovery)/) next
      gsub(/\\/,"\\\\",device); gsub(/"/,"\\\"",device)
      gsub(/\\/,"\\\\",mp); gsub(/"/,"\\\"",mp)
      if (first) printf ","; first=1
      printf "{\"device\":\"%s\",\"mountpoint\":\"%s\",\"fstype\":\"%s\",\"total_bytes\":%d,\"used_bytes\":%d,\"free_bytes\":%d,\"use_percent\":%s}", device,mp,"apfs",total,used,free,(pct+0)
    }
    END{printf "]"}'
}

collect_services() {
  command -v launchctl >/dev/null 2>&1 || { printf "[]"; return; }
  launchctl list 2>/dev/null | awk '
    BEGIN{printf "["; first=1}
    NR==1{next}
    {
      pid=$1; status=$2; name=$3;
      if (name=="" || name ~ /^0x/) next;
      st=(pid ~ /^[0-9]+$/ && pid+0>0) ? "running" : (status!="0" && status!="-" ? "failed" : "stopped");
      gsub(/\\/,"\\\\",name); gsub(/"/,"\\\"",name);
      if(!first) printf ","; first=0;
      printf "{\"name\":\"%s\",\"display_name\":\"%s\",\"status\":\"%s\",\"type\":\"launchd\"}", name, name, st;
    }
    END{printf "]"}'
}

encrypt_payload() {
  command -v openssl >/dev/null 2>&1 || { printf ""; return 1; }
  printf '%s' "$1" | openssl enc -aes-256-cbc -pbkdf2 -iter 10000 -salt -base64 -A \
    -pass "pass:$AGENT_TOKEN" 2>/dev/null
}

post_json() {
  url="$1"; body="$2"
  enc_body=$(encrypt_payload "$body" 2>/dev/null || true)
  if [ -n "$enc_body" ]; then
    HTTP=$(curl -sS --connect-timeout 10 --max-time 30 -o "$RESP_FILE" -w "%{http_code}" -X POST "$url" \
      -H "Content-Type: text/plain" \
      -H "X-Encrypted: aes-256-cbc-pbkdf2" \
      -H "Authorization: Bearer $AGENT_TOKEN" \
      --data "$enc_body") || HTTP="000"
  else
    HTTP=$(curl -sS --connect-timeout 10 --max-time 30 -o "$RESP_FILE" -w "%{http_code}" -X POST "$url" \
      -H "Content-Type: application/json; charset=utf-8" \
      -H "Authorization: Bearer $AGENT_TOKEN" \
      --data "$body") || HTTP="000"
  fi
  case "$HTTP" in
    2*) return 0 ;;
    *) echo "[$(now_iso)] POST $url failed http=$HTTP body=$(cat "$RESP_FILE" 2>/dev/null)" >&2; return 1 ;;
  esac
}

PROC_URL=$(printf '%s' "$INGEST_URL" | sed 's|/metrics$|/processes|')
PORTS_URL=$(printf '%s' "$INGEST_URL" | sed 's|/metrics$|/ports|')
DISKS_URL=$(printf '%s' "$INGEST_URL" | sed 's|/metrics$|/disks|')
SERVICES_URL=$(printf '%s' "$INGEST_URL" | sed 's|/metrics$|/services|')

trap 'rm -f "$RESP_FILE"' EXIT
echo "[$(now_iso)] torobyte-agent $AGENT_VERSION started interval=${INTERVAL}s endpoint=${INGEST_URL}"

AGENT_BASE_VERSION=$(printf '%s' "$AGENT_VERSION" | sed 's/-.*$//')
SELF_UPDATE_URL=$(printf '%s' "$INGEST_URL" | sed 's|/api/public/ingest/metrics.*|/api/public/agents/macos.sh|')

check_self_update() {
  [ -s "$RESP_FILE" ] || return 0
  UPDATE_TO=$(grep -o '"update_to":"[^"]*"' "$RESP_FILE" 2>/dev/null | head -1 | sed 's/.*:"//;s/"$//')
  [ -n "$UPDATE_TO" ] && [ "$UPDATE_TO" != "null" ] || return 0
  if [ "$UPDATE_TO" = "$AGENT_BASE_VERSION" ]; then return 0; fi
  echo "[$(now_iso)] update_to=$UPDATE_TO solicitada — reinstalando agente"
  TMP_NEW="/tmp/torobyte-agent.new.$$"
  if curl -fsSL "$SELF_UPDATE_URL" -o "$TMP_NEW"; then
    AGENT_TOKEN="$AGENT_TOKEN" INGEST_URL="$INGEST_URL" INTERVAL="$INTERVAL" \
      /bin/sh "$TMP_NEW" install >>"$LOG_PATH" 2>&1 &
    sleep 1
    exit 0
  fi
  rm -f "$TMP_NEW" 2>/dev/null
}

apply_interval() {
  [ -s "$RESP_FILE" ] || return 0
  NEW_INT=$(grep -o '"interval":[0-9]*' "$RESP_FILE" 2>/dev/null | head -1 | sed 's/.*://')
  case "$NEW_INT" in ''|*[!0-9]*) return 0 ;; esac
  [ "$NEW_INT" -lt 60 ] && NEW_INT=60
  [ "$NEW_INT" -gt 86400 ] && NEW_INT=86400
  if [ "$NEW_INT" != "$INTERVAL" ]; then
    echo "[$(now_iso)] interval cambiado ${INTERVAL}s -> ${NEW_INT}s"
    INTERVAL="$NEW_INT"
  fi
}

while true; do
  BODY=$(collect)
  if post_json "$INGEST_URL" "$BODY"; then
    echo "[$(now_iso)] metrics ok"
    check_self_update
    apply_interval
  fi

  # En modo ONCE (prueba de instalación) solo enviamos métricas — los demás
  # colectores (especialmente lsof) pueden ser muy lentos en Apple Silicon
  # y causarían que step 5 supere el timeout.
  if [ "$ONCE" = "1" ]; then exit 0; fi

  PROCS=$(collect_processes 2>/dev/null || echo "[]")
  post_json "$PROC_URL" "{\"processes\":$PROCS}" >/dev/null 2>&1 || true
  PORTS=$(collect_ports 2>/dev/null || echo "[]")
  post_json "$PORTS_URL" "{\"ports\":$PORTS}" >/dev/null 2>&1 || true
  DISKS=$(collect_disks 2>/dev/null || echo "[]")
  post_json "$DISKS_URL" "{\"disks\":$DISKS}" >/dev/null 2>&1 || true
  SERVICES=$(collect_services 2>/dev/null || echo "[]")
  post_json "$SERVICES_URL" "{\"services\":$SERVICES}" >/dev/null 2>&1 || true

  sleep "$INTERVAL"
done
