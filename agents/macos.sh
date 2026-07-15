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
INTERVAL="${INTERVAL:-5}"
ONCE="${ONCE:-0}"
AGENT_VERSION="2.0.3-macos"
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

  step 4 $TOTAL "Preparando agente..."
  if [ -r "$0" ] && head -n 1 "$0" 2>/dev/null | grep -q '^#!/bin/sh'; then
    cp "$0" "$AGENT_SCRIPT" || fail "no se pudo copiar el instalador local"
    ok "copiado desde instalador local (sin nueva descarga)"
  else
    AGENT_SCRIPT_URL="${AGENT_SCRIPT_URL:-$(printf '%s' "$INGEST_URL" | sed 's|/api/public/ingest/metrics.*|/api/public/agents/macos.sh|')}"
    RAW_AGENT_URL="https://raw.githubusercontent.com/torobyte/servidoresagentes/main/agents/macos.sh"
    dl_agent() {
      _u="$1"
      curl -fsSL --connect-timeout 8 --max-time 40 -o "$AGENT_SCRIPT" "$_u" 2>/dev/null && return 0
      curl -fsSL --tlsv1.2 --connect-timeout 8 --max-time 40 -o "$AGENT_SCRIPT" "$_u" 2>/dev/null && return 0
      curl -fsSLk --connect-timeout 8 --max-time 40 -o "$AGENT_SCRIPT" "$_u" 2>/dev/null && return 0
      command -v wget >/dev/null 2>&1 && wget -q --no-check-certificate -O "$AGENT_SCRIPT" "$_u" 2>/dev/null && return 0
      return 1
    }
    _dl_ok=0
    for _src in "$RAW_AGENT_URL" "$AGENT_SCRIPT_URL"; do
      [ -n "$_src" ] || continue
      [ "$_src" = "https://raw.githubusercontent.com/torobyte/servidoresagentes/main/agents/macos.sh" ] && continue
      if dl_agent "$_src"; then _dl_ok=1; ok "descargado desde $_src"; break; fi
      printf "      \033[1;33m!\033[0m descarga fallida desde %s, probando siguiente...\n" "$_src" >&2
    done
    [ "$_dl_ok" = "1" ] || fail "no se pudo descargar el agente (probado: $RAW_AGENT_URL $AGENT_SCRIPT_URL)"
  fi
  head -n 1 "$AGENT_SCRIPT" | grep -q '^#!/bin/sh' || fail "la descarga no es un script válido"
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
    tail -n 40 "$LOG_PATH" 2>/dev/null >&2 || true
    fail "el LaunchDaemon no quedó activo"
  fi

  # Espera activa hasta ver la primera métrica en el log del daemon (max 60s).
  printf "      esperando primera métrica del daemon..."
  _seen=0
  _i=0
  while [ $_i -lt 30 ]; do
    if grep -q "metrics ok" "$LOG_PATH" 2>/dev/null; then _seen=1; break; fi
    printf "."
    sleep 2
    _i=$((_i + 1))
  done
  printf "\n"
  if [ "$_seen" = "1" ]; then
    ok "daemon enviando métricas correctamente"
  else
    printf "      \033[1;33m!\033[0m no se detectaron métricas en 60s. Últimas líneas del log:\n" >&2
    tail -n 40 "$LOG_PATH" 2>/dev/null >&2 || true
    printf "      \033[1;33m!\033[0m revisa la salida anterior y comparte el log: %s\n" "$LOG_PATH" >&2
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
case "$INTERVAL" in ''|*[!0-9]*) INTERVAL=5 ;; esac
[ "$INTERVAL" -lt 5 ] && INTERVAL=5

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
  # macOS no expone uso por núcleo en shell puro (requeriría powermetrics
  # con sudo). Omitimos el campo para que la UI muestre el placeholder honesto.

  gpu=$(system_profiler SPDisplaysDataType 2>/dev/null | awk -F': ' '/Chipset Model/{print $2; exit}')
  [ -n "$gpu" ] || gpu="GPU desconocida"
  motherboard=$(sysctl -n hw.model 2>/dev/null)
  [ -n "$motherboard" ] || motherboard="Apple"
  mac_addr=$(ifconfig 2>/dev/null | awk '/^[a-z]/{iface=$1; sub(":","",iface)} /ether/{if(iface!="lo0") printf "%s%s=%s", (n++?",":""), iface, $2}')

  latency_ms=$(ping -c 1 -W 1000 1.1.1.1 2>/dev/null | awk -F'time=' '/time=/{split($2,t," "); printf "%d", t[1]+0.5; exit}')
  case "$latency_ms" in ''|*[!0-9]*) latency_ms=0 ;; esac

  hw_manuf="Apple Inc."
  hw_model=$(sysctl -n hw.model 2>/dev/null)
  [ -n "$hw_model" ] || hw_model=""
  serial_number=$(ioreg -rd1 -c IOPlatformExpertDevice 2>/dev/null | awk -F'"' '/IOPlatformSerialNumber/ {print $4; exit}')
  [ -n "$serial_number" ] || serial_number=""

  cat <<EOF
{"hostname":"$(json_escape "$hostname_v")","os":"$(json_escape "$os_name")","kernel":"$(json_escape "$kernel")","arch":"$(json_escape "$arch")","cores":$cores,"cpu_model":"$(json_escape "$cpu_model")","total_ram":"$(json_escape "$tram")","total_disk":"$(json_escape "$tdisk")","public_ip":"$(json_escape "$pub")","private_ip":"$(json_escape "$priv")","uptime":"$(json_escape "$up")","cpu":$cpu,"ram":$ram,"disk":$disk,"network_in":$net_in,"network_out":$net_out,"load_avg":{"1":$l1,"5":$l5,"15":$l15},"gpu":"$(json_escape "$gpu")","motherboard":"$(json_escape "$motherboard")","mac_address":"$(json_escape "$mac_addr")","manufacturer":"$(json_escape "$hw_manuf")","hw_model":"$(json_escape "$hw_model")","serial_number":"$(json_escape "$serial_number")","latency_ms":$latency_ms,"agent_version":"$AGENT_VERSION"}
EOF
}

collect_processes() {
  ps -axo pid=,user=,pcpu=,pmem=,rss=,comm=,command= -r 2>/dev/null | head -n 200 | awk '
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
      --data "$enc_body") || \
    HTTP=$(curl -sS --tlsv1.2 --connect-timeout 10 --max-time 30 -o "$RESP_FILE" -w "%{http_code}" -X POST "$url" \
      -H "Content-Type: text/plain" \
      -H "X-Encrypted: aes-256-cbc-pbkdf2" \
      -H "Authorization: Bearer $AGENT_TOKEN" \
      --data "$enc_body") || \
    HTTP=$(curl -sSk --connect-timeout 10 --max-time 30 -o "$RESP_FILE" -w "%{http_code}" -X POST "$url" \
      -H "Content-Type: text/plain" \
      -H "X-Encrypted: aes-256-cbc-pbkdf2" \
      -H "Authorization: Bearer $AGENT_TOKEN" \
      --data "$enc_body") || HTTP="000"
  else
    HTTP=$(curl -sS --connect-timeout 10 --max-time 30 -o "$RESP_FILE" -w "%{http_code}" -X POST "$url" \
      -H "Content-Type: application/json; charset=utf-8" \
      -H "Authorization: Bearer $AGENT_TOKEN" \
      --data "$body") || \
    HTTP=$(curl -sS --tlsv1.2 --connect-timeout 10 --max-time 30 -o "$RESP_FILE" -w "%{http_code}" -X POST "$url" \
      -H "Content-Type: application/json; charset=utf-8" \
      -H "Authorization: Bearer $AGENT_TOKEN" \
      --data "$body") || \
    HTTP=$(curl -sSk --connect-timeout 10 --max-time 30 -o "$RESP_FILE" -w "%{http_code}" -X POST "$url" \
      -H "Content-Type: application/json; charset=utf-8" \
      -H "Authorization: Bearer $AGENT_TOKEN" \
      --data "$body") || HTTP="000"
  fi
  case "$HTTP" in
    2*)
      if grep -q '"ok"[[:space:]]*:[[:space:]]*true' "$RESP_FILE" 2>/dev/null; then return 0; fi
      echo "[$(now_iso)] POST $url respuesta inesperada http=$HTTP body=$(cat "$RESP_FILE" 2>/dev/null)" >&2
      return 1
      ;;
    *) echo "[$(now_iso)] POST $url failed http=$HTTP body=$(cat "$RESP_FILE" 2>/dev/null)" >&2; return 1 ;;
  esac
}

PUBLIC_INGEST_BASE="${PUBLIC_INGEST_BASE:-https://project--de5cadf8-756e-4d2f-8f8b-6ca62009361b-dev.lovable.app/api/public/ingest}"
derive_ingest_url() {
  suffix="$1"
  case "$INGEST_URL" in
    *functions.supabase.co/ingest-metrics*) printf '%s/%s' "$PUBLIC_INGEST_BASE" "$suffix" ;;
    */metrics) printf '%s' "$INGEST_URL" | sed "s|/metrics$|/$suffix|" ;;
    *) printf '%s/%s' "$PUBLIC_INGEST_BASE" "$suffix" ;;
  esac
}
PROC_URL=$(derive_ingest_url processes)
PORTS_URL=$(derive_ingest_url ports)
DISKS_URL=$(derive_ingest_url disks)
SERVICES_URL=$(derive_ingest_url services)
APPS_URL=$(derive_ingest_url apps)
SESSIONS_URL=$(derive_ingest_url sessions)

# -------------------------- Aplicaciones (uso) --------------------------
APPS_STATE_DIR="${TMPDIR:-/tmp}/torobyte-apps"
APP_SEND_EVERY=1       # enviar apps en cada ciclo para diagnóstico y control desde plataforma
APPS_LOOP=0
mkdir -p "$APPS_STATE_DIR" 2>/dev/null || true
APP_LAST_SAMPLE_FILE="$APPS_STATE_DIR/last-sample"

console_user() {
  stat -f %Su /dev/console 2>/dev/null | tr -d '\n'
}

foreground_app() {
  cu=$(console_user)
  [ -n "$cu" ] && [ "$cu" != "root" ] || return 0
  uid=$(id -u "$cu" 2>/dev/null || echo "")
  [ -n "$uid" ] || return 0
  name=""
  # 1) lsappinfo — no requiere permisos TCC de Accesibilidad
  if command -v lsappinfo >/dev/null 2>&1; then
    asn=$(launchctl asuser "$uid" sudo -u "$cu" lsappinfo front 2>/dev/null | tr -d '\n')
    if [ -n "$asn" ]; then
      name=$(launchctl asuser "$uid" sudo -u "$cu" lsappinfo info -only name "$asn" 2>/dev/null | sed -n 's/.*"LSDisplayName"="\([^"]*\)".*/\1/p' | head -1)
    fi
  fi
  # 2) fallback: osascript (puede fallar sin permisos de Accesibilidad concedidos al daemon)
  if [ -z "$name" ] && command -v launchctl >/dev/null 2>&1; then
    name=$(launchctl asuser "$uid" sudo -u "$cu" osascript -e 'tell application "System Events" to name of first application process whose frontmost is true' 2>/dev/null)
  fi
  # 3) fallback: ps con apps GUI del usuario (ordenadas por CPU)
  if [ -z "$name" ]; then
    name=$(ps -axo user=,pcpu=,command= 2>/dev/null | awk -v u="$cu" '$1==u && $0 ~ /\.app\// {
      cpu=$2; $1=""; $2=""; sub(/^ +/,"");
      n=split($0,a,"/"); app="";
      for(i=1;i<=n;i++) if(a[i] ~ /\.app$/){app=a[i]; sub(/\.app$/,"",app); break}
      if (app!="" && app !~ /(Helper|Agent|Daemon|Service|XPC)$/) print cpu" "app
    }' | sort -rn | head -1 | awk '{$1=""; sub(/^ +/,""); print}')
  fi
  [ -n "$name" ] && printf '%s' "$name"
}

open_apps() {
  cu=$(console_user)
  uid=$(id -u "$cu" 2>/dev/null || echo "")
  {
    # Sólo apps GUI del usuario (ventanas/aplicaciones visibles para el usuario).
    # No usamos ps aquí: eso mezcla helpers, agentes y procesos de sistema.
    if [ -n "$uid" ] && command -v launchctl >/dev/null 2>&1; then
      launchctl asuser "$uid" sudo -u "$cu" osascript -e 'tell application "System Events" to get name of every application process whose background only is false' 2>/dev/null | tr ',' '\n' | sed 's/^ *//;s/ *$//'
    fi
    # Fallback sin permisos de Accesibilidad: extrae sólo bundles .app del
    # usuario de consola, no procesos sueltos del sistema.
    ps -axo user=,comm= 2>/dev/null | awk -v u="$cu" '$1==u {
      $1=""; sub(/^ */,"");
      if ($0 !~ /\.app\//) next;
      n=split($0,a,"/");
      for(i=1;i<=n;i++) if(a[i] ~ /\.app$/){ app=a[i]; sub(/\.app$/,"",app); break; }
      if (app=="" || app ~ /^(Dock|Finder|SystemUIServer|ControlCenter|NotificationCenter)$/) next;
      if (app ~ /(Helper|Agent|Daemon|Service)$/) next;
      print app; app="";
    }'
  } | awk 'NF && !seen[$0]++ {print}'
}

app_key() {
  if command -v iconv >/dev/null 2>&1; then
    printf '%s' "$1" | iconv -f UTF-8 -t ASCII//TRANSLIT 2>/dev/null
  else
    printf '%s' "$1"
  fi | tr 'A-Z' 'a-z' | tr -c 'a-z0-9._-' '_' | tr -s '_' | sed 's/^_*//;s/_*$//' | cut -c1-60
}

sample_delta() {
  now=$(date +%s)
  last=0; [ -f "$APP_LAST_SAMPLE_FILE" ] && last=$(cat "$APP_LAST_SAMPLE_FILE" 2>/dev/null | tr -cd 0-9)
  echo "$now" > "$APP_LAST_SAMPLE_FILE" 2>/dev/null || true
  if [ -z "$last" ] || [ "$last" -le 0 ]; then delta="${INTERVAL:-5}"; else delta=$((now - last)); fi
  [ "$delta" -lt 1 ] && delta=1
  [ "$delta" -gt 300 ] && delta=300
  printf '%s' "$delta"
}

bump() {
  f="$1"; delta="$2"
  cur=0; [ -f "$f" ] && cur=$(cat "$f" 2>/dev/null | tr -cd 0-9)
  [ -z "$cur" ] && cur=0
  echo $((cur + delta)) > "$f"
}
touch_seen() {
  day="$1"; kind="$2"; name="$3"; nowiso="$4"; label="${5:-$3}"
  fs="$APPS_STATE_DIR/$day.first.$kind.$name"
  ls_="$APPS_STATE_DIR/$day.last.$kind.$name"
  lb="$APPS_STATE_DIR/$day.label.$name"
  [ -f "$fs" ] || echo "$nowiso" > "$fs"
  echo "$nowiso" > "$ls_"
  [ -f "$lb" ] || printf '%s' "$label" > "$lb"
}

sample_apps() {
  day=$(date -u +%Y-%m-%d)
  nowiso=$(now_iso)
  delta=$(sample_delta)
  fg=$(foreground_app 2>/dev/null || true)
  if [ -n "$fg" ]; then
    safe=$(app_key "$fg")
    [ -n "$safe" ] && bump "$APPS_STATE_DIR/$day.active.$safe" "$delta"
    [ -n "$safe" ] && touch_seen "$day" "active" "$safe" "$nowiso" "$fg"
  fi
  open_apps 2>/dev/null | while IFS= read -r name; do
    [ -n "$name" ] || continue
    safe=$(app_key "$name")
    [ -n "$safe" ] || continue
    bump "$APPS_STATE_DIR/$day.open.$safe" "$delta"
    touch_seen "$day" "open" "$safe" "$nowiso" "$name"
  done
}

build_apps_body() {
  day=$(date -u +%Y-%m-%d)
  names=$(for f in "$APPS_STATE_DIR/$day.active."* "$APPS_STATE_DIR/$day.open."*; do
    [ -e "$f" ] || continue
    b=$(basename "$f")
    printf '%s\n' "$b" | sed "s/^$day\.active\.//;s/^$day\.open\.//"
  done | sort -u)
  [ -z "$names" ] && return 1
  printf '{"date":"%s","mode":"delta","apps":[' "$day"
  first=1
  for n in $names; do
    active=0; open=0; fs=""; ls_=""
    label="$n"; [ -f "$APPS_STATE_DIR/$day.label.$n" ] && label=$(cat "$APPS_STATE_DIR/$day.label.$n" 2>/dev/null)
    [ -f "$APPS_STATE_DIR/$day.active.$n" ] && active=$(cat "$APPS_STATE_DIR/$day.active.$n" 2>/dev/null | tr -cd 0-9)
    [ -f "$APPS_STATE_DIR/$day.open.$n" ]   && open=$(cat "$APPS_STATE_DIR/$day.open.$n" 2>/dev/null | tr -cd 0-9)
    for k in active open; do
      f="$APPS_STATE_DIR/$day.first.$k.$n"
      [ -f "$f" ] && { fs=$(cat "$f" 2>/dev/null); break; }
    done
    for k in active open; do
      l="$APPS_STATE_DIR/$day.last.$k.$n"
      [ -f "$l" ] && ls_=$(cat "$l" 2>/dev/null)
    done
    [ "$first" = "1" ] || printf ','
    first=0
    printf '{"key":"%s","label":"%s","source":"gui","seconds_active":%s,"seconds_open":%s,"first_seen":"%s","last_seen":"%s"}' \
      "$(json_escape "$n")" "$(json_escape "$label")" "${active:-0}" "${open:-0}" "$(json_escape "$fs")" "$(json_escape "$ls_")"
  done
  printf ']}'
}

send_apps() {
  BODY=$(build_apps_body) || return 0
  post_json "$APPS_URL" "$BODY" >/dev/null 2>&1 || return 0
  # Reset counters tras envío exitoso (dejamos first/last del día)
  day=$(date -u +%Y-%m-%d)
  rm -f "$APPS_STATE_DIR/$day.active."* "$APPS_STATE_DIR/$day.open."* 2>/dev/null || true
}

# -------------- Sesiones foreground v2.0.0 (idempotentes por UUID) --------------
SESSIONS_STATE_DIR="${TMPDIR:-/tmp}/torobyte-sessions"
mkdir -p "$SESSIONS_STATE_DIR" 2>/dev/null || true
SESSIONS_FILE="$SESSIONS_STATE_DIR/queue.jsonl"
IDLE_FILE="$SESSIONS_STATE_DIR/idle.jsonl"
CUR_DIR="$SESSIONS_STATE_DIR/current"
CUR_IDLE_DIR="$SESSIONS_STATE_DIR/current-idle"
IDLE_THRESHOLD_SEC="${IDLE_THRESHOLD_SECONDS:-180}"
SESSION_SAMPLE_SEC="${SESSION_SAMPLE_SECONDS:-3}"
[ "$SESSION_SAMPLE_SEC" -lt 1 ] 2>/dev/null && SESSION_SAMPLE_SEC=1
: > "$SESSIONS_FILE" 2>/dev/null || true
: > "$IDLE_FILE" 2>/dev/null || true

new_uuid() {
  if command -v uuidgen >/dev/null 2>&1; then uuidgen | tr 'A-Z' 'a-z'
  else python3 -c 'import uuid;print(uuid.uuid4())' 2>/dev/null || printf '%s-%s-4%s-%s-%s\n' "$(openssl rand -hex 4)" "$(openssl rand -hex 2)" "$(openssl rand -hex 3 | cut -c2-)" "$(openssl rand -hex 2)" "$(openssl rand -hex 6)"
  fi
}

idle_seconds() {
  ioreg -c IOHIDSystem 2>/dev/null | awk '/HIDIdleTime/ {print int($NF/1000000000); exit}' | tr -cd 0-9
}

iso_to_epoch() {
  date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$1" +%s 2>/dev/null || echo 0
}

read_field() {
  [ -f "$1/$2" ] && cat "$1/$2" || printf ''
}

write_current_session() {
  rm -rf "$CUR_DIR" 2>/dev/null
  mkdir -p "$CUR_DIR" 2>/dev/null || return 1
  printf '%s' "$1" > "$CUR_DIR/uuid"
  printf '%s' "$2" > "$CUR_DIR/app"
  printf '%s' "$3" > "$CUR_DIR/proc"
  printf '%s' "$4" > "$CUR_DIR/started"
  printf '%s' "$5" > "$CUR_DIR/user"
}

write_current_idle() {
  rm -rf "$CUR_IDLE_DIR" 2>/dev/null
  mkdir -p "$CUR_IDLE_DIR" 2>/dev/null || return 1
  printf '%s' "$1" > "$CUR_IDLE_DIR/uuid"
  printf '%s' "$2" > "$CUR_IDLE_DIR/started"
  printf '%s' "$3" > "$CUR_IDLE_DIR/user"
}

emit_session_json() {
  printf '{"session_uuid":"%s","application_name":"%s","process_name":"%s","bundle_id":null,"window_title":null,"started_at":"%s","ended_at":"%s","duration_seconds":%s,"foreground":true,"window_visible":true,"idle_interrupted":%s,"os_user":"%s"}\n' \
    "$1" "$(json_escape "$2")" "$(json_escape "$3")" "$4" "$5" "$6" "$7" "$(json_escape "$8")"
}

close_current_session() {
  end_iso="$1"; interrupted="${2:-false}"
  [ -d "$CUR_DIR" ] || return 0
  s_uuid=$(read_field "$CUR_DIR" uuid)
  s_app=$(read_field "$CUR_DIR" app)
  s_proc=$(read_field "$CUR_DIR" proc)
  s_started=$(read_field "$CUR_DIR" started)
  s_user=$(read_field "$CUR_DIR" user)
  [ -z "$s_uuid" ] && { rm -rf "$CUR_DIR"; return 0; }
  st=$(iso_to_epoch "$s_started")
  et=$(iso_to_epoch "$end_iso"); [ "$et" -eq 0 ] && et=$(date -u +%s)
  dur=$((et - st))
  [ "$dur" -le 0 ] && { rm -rf "$CUR_DIR"; return 0; }
  emit_session_json "$s_uuid" "$s_app" "$s_proc" "$s_started" "$end_iso" "$dur" "$interrupted" "$s_user" >> "$SESSIONS_FILE"
  rm -rf "$CUR_DIR"
}

sample_session() {
  now_iso=$(now_iso)
  idle=$(idle_seconds); [ -z "$idle" ] && idle=0
  if [ "$idle" -ge "$IDLE_THRESHOLD_SEC" ]; then
    [ -d "$CUR_DIR" ] && close_current_session "$now_iso" true
    if [ ! -d "$CUR_IDLE_DIR" ]; then
      write_current_idle "$(new_uuid)" "$now_iso" "$(console_user)"
    fi
    return 0
  fi
  if [ -d "$CUR_IDLE_DIR" ]; then
    i_uuid=$(read_field "$CUR_IDLE_DIR" uuid)
    i_started=$(read_field "$CUR_IDLE_DIR" started)
    i_user=$(read_field "$CUR_IDLE_DIR" user)
    if [ -n "$i_uuid" ]; then
      ist=$(iso_to_epoch "$i_started")
      iet=$(iso_to_epoch "$now_iso"); [ "$iet" -eq 0 ] && iet=$(date -u +%s)
      idur=$((iet - ist)); [ "$idur" -lt 0 ] && idur=0
      printf '{"session_uuid":"%s","started_at":"%s","ended_at":"%s","duration_seconds":%s,"reason":"idle","os_user":"%s"}\n' \
        "$i_uuid" "$i_started" "$now_iso" "$idur" "$(json_escape "$i_user")" >> "$IDLE_FILE"
    fi
    rm -rf "$CUR_IDLE_DIR"
  fi
  fg_name=$(foreground_app 2>/dev/null || true)
  [ -z "$fg_name" ] && return 0
  cu=$(console_user)
  if [ -d "$CUR_DIR" ]; then
    cur_app=$(read_field "$CUR_DIR" app)
    if [ "$cur_app" = "$fg_name" ]; then
      return 0
    fi
    close_current_session "$now_iso" false
  fi
  write_current_session "$(new_uuid)" "$fg_name" "$fg_name" "$now_iso" "$cu"
}

jsonl_to_array() {
  f="$1"
  if [ ! -s "$f" ]; then printf '[]'; return 0; fi
  awk 'BEGIN{printf("[")} NF{ if (n++) printf(","); printf("%s", $0) } END{printf("]")}' "$f"
}

build_sessions_payload() {
  now_iso=$(now_iso)
  if [ -d "$CUR_DIR" ]; then
    s_uuid=$(read_field "$CUR_DIR" uuid)
    s_app=$(read_field "$CUR_DIR" app)
    s_proc=$(read_field "$CUR_DIR" proc)
    s_started=$(read_field "$CUR_DIR" started)
    s_user=$(read_field "$CUR_DIR" user)
    if [ -n "$s_uuid" ]; then
      st=$(iso_to_epoch "$s_started")
      et=$(iso_to_epoch "$now_iso"); [ "$et" -eq 0 ] && et=$(date -u +%s)
      dur=$((et - st))
      if [ "$dur" -gt 0 ]; then
        emit_session_json "$s_uuid" "$s_app" "$s_proc" "$s_started" "$now_iso" "$dur" "false" "$s_user" >> "$SESSIONS_FILE"
      fi
    fi
  fi
  if [ -d "$CUR_IDLE_DIR" ]; then
    i_uuid=$(read_field "$CUR_IDLE_DIR" uuid)
    i_started=$(read_field "$CUR_IDLE_DIR" started)
    i_user=$(read_field "$CUR_IDLE_DIR" user)
    if [ -n "$i_uuid" ]; then
      printf '{"session_uuid":"%s","started_at":"%s","ended_at":null,"duration_seconds":null,"reason":"idle","os_user":"%s"}\n' \
        "$i_uuid" "$i_started" "$(json_escape "$i_user")" >> "$IDLE_FILE"
    fi
  fi
  sessions=$(jsonl_to_array "$SESSIONS_FILE")
  idles=$(jsonl_to_array "$IDLE_FILE")
  printf '{"agent_version":"%s","sessions":%s,"idle_sessions":%s}' "$AGENT_VERSION" "$sessions" "$idles"
}

send_sessions() {
  if [ ! -s "$SESSIONS_FILE" ] && [ ! -s "$IDLE_FILE" ] && [ ! -d "$CUR_DIR" ] && [ ! -d "$CUR_IDLE_DIR" ]; then
    return 0
  fi
  payload=$(build_sessions_payload)
  if post_json "$SESSIONS_URL" "$payload" >/dev/null 2>&1; then
    : > "$SESSIONS_FILE"
    : > "$IDLE_FILE"
  fi
}


trap 'rm -f "$RESP_FILE"' EXIT
echo "[$(now_iso)] torobyte-agent $AGENT_VERSION started interval=${INTERVAL}s endpoint=${INGEST_URL}"

AGENT_BASE_VERSION=$(printf '%s' "$AGENT_VERSION" | sed 's/-.*$//')
case "$INGEST_URL" in
  *functions.supabase.co/ingest-metrics*) SELF_UPDATE_URL="https://project--de5cadf8-756e-4d2f-8f8b-6ca62009361b-dev.lovable.app/api/public/agents/macos.sh" ;;
  *) SELF_UPDATE_URL=$(printf '%s' "$INGEST_URL" | sed 's|/api/public/ingest/metrics.*|/api/public/agents/macos.sh|') ;;
esac

check_self_update() {
  [ -s "$RESP_FILE" ] || return 0
  UPDATE_TO=$(grep -o '"update_to":"[^"]*"' "$RESP_FILE" 2>/dev/null | head -1 | sed 's/.*:"//;s/"$//')
  [ -n "$UPDATE_TO" ] && [ "$UPDATE_TO" != "null" ] || return 0
  if [ "$UPDATE_TO" = "$AGENT_BASE_VERSION" ]; then return 0; fi
  echo "[$(now_iso)] update_to=$UPDATE_TO solicitada — reinstalando agente"
  TMP_NEW="/tmp/torobyte-agent.new.$$"
  if curl -fsSL "$SELF_UPDATE_URL" -o "$TMP_NEW" || curl -fsSLk "$SELF_UPDATE_URL" -o "$TMP_NEW"; then
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
  [ "$NEW_INT" -lt 5 ] && NEW_INT=5
  [ "$NEW_INT" -gt 86400 ] && NEW_INT=86400
  if [ "$NEW_INT" != "$INTERVAL" ]; then
    echo "[$(now_iso)] interval cambiado ${INTERVAL}s -> ${NEW_INT}s"
    INTERVAL="$NEW_INT"
  fi
}

send_runtime_error() {
  msg=$(json_escape "$1")
  post_json "$APPS_URL" "{\"date\":\"$(date -u +%Y-%m-%d)\",\"error\":\"$msg\",\"apps\":[]}" >/dev/null 2>&1 || true
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

  # Uso de aplicaciones (muestreo + envío periódico)
  APP_ERR=$(sample_apps 2>&1 >/dev/null || true)
  [ -n "$APP_ERR" ] && send_runtime_error "apps sample: $APP_ERR"
  APPS_LOOP=$((APPS_LOOP + 1))
  if [ "$APPS_LOOP" -ge "$APP_SEND_EVERY" ]; then
    send_apps 2>/dev/null || true
    APPS_LOOP=0
  fi

  # Sesiones foreground v2.0.0: sub-muestreo dentro del intervalo
  SLEPT=0
  while [ "$SLEPT" -lt "$INTERVAL" ]; do
    sample_session 2>/dev/null || true
    sleep "$SESSION_SAMPLE_SEC"
    SLEPT=$((SLEPT + SESSION_SAMPLE_SEC))
  done
  send_sessions 2>/dev/null || true
done
