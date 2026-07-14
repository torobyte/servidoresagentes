#!/bin/sh
# Torobyte Monitor Cloud - macOS agent (Apple Silicon / arm64)
# Compatible: macOS 11+ en chips M1/M2/M3/M4
set -u

AGENT_TOKEN="${AGENT_TOKEN:-${TOKEN:-}}"
INGEST_URL="${INGEST_URL:-${URL:-}}"
INTERVAL="${INTERVAL:-5}"
ONCE="${ONCE:-0}"
AGENT_VERSION="2.0.0-macos-arm64"
MODE="${1:-run}"

INSTALL_DIR="/usr/local/torobyte-agent"
AGENT_SCRIPT="$INSTALL_DIR/torobyte-agent.sh"
PLIST_PATH="/Library/LaunchDaemons/com.torobyte.agent.plist"
LOG_PATH="/var/log/torobyte-agent.log"
LABEL="com.torobyte.agent"

step() { printf "\033[1;36m[%s/%s]\033[0m %s\n" "$1" "$2" "$3"; }
ok()   { printf "      \033[1;32m✓\033[0m %s\n" "$1"; }
fail() { printf "      \033[1;31m✗\033[0m %s\n" "$1" >&2; exit 1; }

if [ "$MODE" = "install" ]; then
  TOTAL=7
  printf "\n\033[1m🛠  Torobyte Monitor Agent (Apple Silicon) — Instalación %s\033[0m\n\n" "$AGENT_VERSION"

  step 1 $TOTAL "Validando parámetros..."
  [ -n "$AGENT_TOKEN" ] || fail "AGENT_TOKEN (o TOKEN) requerido"
  [ -n "$INGEST_URL" ] || fail "INGEST_URL (o URL) requerido"
  ok "token=${AGENT_TOKEN%${AGENT_TOKEN#????????}}…  url=$INGEST_URL"

  step 2 $TOTAL "Verificando privilegios (sudo/root) y arquitectura arm64..."
  [ "$(id -u)" = "0" ] || fail "se requiere sudo/root para instalar el LaunchDaemon"
  ARCH=$(uname -m 2>/dev/null)
  case "$ARCH" in
    arm64|aarch64) ok "arch=$ARCH" ;;
    *) fail "Este agente es exclusivo para Apple Silicon (arm64). Detectado: $ARCH — usa el instalador de macOS Intel." ;;
  esac

  step 3 $TOTAL "Creando carpeta de instalación: $INSTALL_DIR"
  mkdir -p "$INSTALL_DIR" || fail "no se pudo crear $INSTALL_DIR"
  ok "OK"

  step 4 $TOTAL "Preparando agente (variante arm64)..."
  if [ -r "$0" ] && head -n 1 "$0" 2>/dev/null | grep -q '^#!/bin/sh'; then
    cp "$0" "$AGENT_SCRIPT" || fail "no se pudo copiar el instalador local"
    ok "copiado desde instalador local (sin nueva descarga)"
  else
    AGENT_SCRIPT_URL="${AGENT_SCRIPT_URL:-$(printf '%s' "$INGEST_URL" | sed 's|/api/public/ingest/metrics.*|/api/public/agents/macos-arm64.sh|')}"
    RAW_AGENT_URL="https://raw.githubusercontent.com/torobyte/servidoresagentes/main/agents/macos-arm64.sh"
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
      [ "$_src" = "https://raw.githubusercontent.com/torobyte/servidoresagentes/main/agents/macos-arm64.sh" ] && continue
      if dl_agent "$_src"; then _dl_ok=1; ok "descargado desde $_src"; break; fi
      printf "      \033[1;33m!\033[0m descarga fallida desde %s, probando siguiente...\n" "$_src" >&2
    done
    [ "$_dl_ok" = "1" ] || fail "no se pudo descargar el agente (probado: $RAW_AGENT_URL $AGENT_SCRIPT_URL)"
  fi
  head -n 1 "$AGENT_SCRIPT" | grep -q '^#!/bin/sh' || fail "la descarga no es un script (¿URL incorrecta?)"
  chmod +x "$AGENT_SCRIPT"
  ok "$(wc -c <"$AGENT_SCRIPT" | tr -d ' ') bytes"

  step 5 $TOTAL "Enviando primera métrica de prueba (timeout 20s)..."
  if AGENT_TOKEN="$AGENT_TOKEN" INGEST_URL="$INGEST_URL" ONCE=1 /bin/sh "$AGENT_SCRIPT" >/tmp/torobyte-first.log 2>&1 &
  then
    PID=$!
    i=0
    while kill -0 "$PID" 2>/dev/null; do
      i=$((i+1))
      [ $i -gt 20 ] && kill -9 "$PID" 2>/dev/null && break
      sleep 1
    done
    wait "$PID" 2>/dev/null
    RC=$?
    if [ $RC -eq 0 ]; then
      ok "OK — el servidor pasará a 'en línea'"
    else
      cat /tmp/torobyte-first.log >&2 || true
      fail "no se pudo enviar la primera métrica (rc=$RC)"
    fi
  else
    fail "no se pudo lanzar la prueba"
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
  <array><string>/bin/sh</string><string>$AGENT_SCRIPT</string></array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>AGENT_TOKEN</key><string>$AGENT_TOKEN</string>
    <key>INGEST_URL</key><string>$INGEST_URL</string>
    <key>INTERVAL</key><string>$INTERVAL</string>
    <key>PATH</key><string>/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
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
    ok "LaunchDaemon cargado"
  else
    launchctl load -w "$PLIST_PATH" >/dev/null 2>&1 || fail "no se pudo cargar el LaunchDaemon"
    ok "LaunchDaemon cargado (load)"
  fi

  step 7 $TOTAL "Verificando estado..."
  sleep 2
  if launchctl list 2>/dev/null | grep -q "$LABEL"; then
    ok "agente en ejecución"
  else
    tail -n 30 "$LOG_PATH" 2>/dev/null >&2 || true
    fail "el LaunchDaemon no quedó activo"
  fi

  printf "\n\033[1;32m✔ Instalación completada (Apple Silicon)\033[0m\n"
  printf "  log: %s\n\n" "$LOG_PATH"
  exit 0
fi

if [ "$MODE" = "uninstall" ] || [ "$MODE" = "remove" ]; then
  printf "\n\033[1m🗑  Torobyte Agent (arm64) — Desinstalación\033[0m\n\n"
  [ "$(id -u)" = "0" ] || fail "se requiere sudo/root"
  launchctl bootout system "$PLIST_PATH" >/dev/null 2>&1 || true
  launchctl unload "$PLIST_PATH" >/dev/null 2>&1 || true
  rm -f "$PLIST_PATH"
  pkill -f "$AGENT_SCRIPT" 2>/dev/null || true
  rm -rf "$INSTALL_DIR"
  rm -f "$LOG_PATH" /tmp/torobyte-first.log
  ok "agente desinstalado"
  exit 0
fi

# -------------------------- Runtime --------------------------
RESP_FILE="${TMPDIR:-/tmp}/torobyte-agent.$$.resp"
case "$INTERVAL" in ''|*[!0-9]*) INTERVAL=5 ;; esac
[ "$INTERVAL" -lt 5 ] && INTERVAL=5

[ -n "$AGENT_TOKEN" ] && [ -n "$INGEST_URL" ] || { echo "AGENT_TOKEN y INGEST_URL requeridos" >&2; exit 1; }
command -v curl >/dev/null 2>&1 || { echo "curl requerido" >&2; exit 1; }

json_escape() { printf '%s' "${1:-}" | tr '\n' ' ' | awk 'BEGIN{ORS=""}{gsub(/\\/,"\\\\"); gsub(/"/,"\\\""); print}'; }
safe_number() { awk -v v="${1:-0}" 'BEGIN{if (v ~ /^-?[0-9]+([.][0-9]+)?$/) printf "%s", v+0; else printf "0"}'; }
safe_int()    { awk -v v="${1:-0}" 'BEGIN{if (v ~ /^[0-9]+$/) printf "%d", v; else printf "0"}'; }
now_iso()     { date -u +"%Y-%m-%dT%H:%M:%SZ"; }

# CPU rápido en Apple Silicon: leemos load_avg y derivamos % uso sobre cores.
# Evitamos top -l/-s (lento en arm64) y ps -A (suma de %cpu poco fiable).
cpu_usage() {
  cores=$(sysctl -n hw.logicalcpu 2>/dev/null); [ "$cores" -gt 0 ] || cores=1
  l1=$(sysctl -n vm.loadavg 2>/dev/null | awk '{gsub(/[{}]/,""); print $1+0}')
  awk -v l="${l1:-0}" -v c="$cores" 'BEGIN{u=l*100/c; if(u>100)u=100; printf "%.1f", u}'
}

ram_usage() {
  page=$(sysctl -n hw.pagesize 2>/dev/null); [ -n "$page" ] || page=16384
  total=$(sysctl -n hw.memsize 2>/dev/null); [ -n "$total" ] || total=0
  vm_stat 2>/dev/null | awk -v page="$page" -v total="$total" '
    /Pages active/                  {act=$3+0}
    /Pages wired down/              {wir=$4+0}
    /Pages occupied by compressor/  {cmp=$5+0}
    END{ if(total<=0){print 0; exit} used=(act+wir+cmp)*page; printf "%.1f", used*100/total }'
}

total_ram() { bytes=$(sysctl -n hw.memsize 2>/dev/null); awk -v b="${bytes:-0}" 'BEGIN{ if(b<=0){print "0 GB"; exit} printf "%.1f GB", b/1024/1024/1024 }'; }
disk_root() { df -k / 2>/dev/null | awk 'NR==2 {gsub("%","",$5); print $5+0}'; }
total_disk() { df -k / 2>/dev/null | awk 'NR==2 {kb=$2; gb=kb/1024/1024; if(gb>=1024) printf "%.2f TB", gb/1024; else printf "%.1f GB", gb}'; }

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

private_ip() {
  for i in en0 en1 en2 en3; do
    ip=$(ipconfig getifaddr "$i" 2>/dev/null)
    [ -n "$ip" ] && { printf '%s' "$ip"; return; }
  done
}
public_ip() {
  curl -fsS --connect-timeout 3 --max-time 5 https://api.ipify.org 2>/dev/null | tr -d '\n\r '
}

NET_STATE="${TMPDIR:-/tmp}/torobyte-net.state"
net_io() {
  totals=$(netstat -ibn 2>/dev/null | awk 'NR>1 && $1!="lo0" && $1!=prev {rx+=$7; tx+=$10; prev=$1} END{print rx+0, tx+0}')
  cur_rx=$(echo "$totals" | awk '{print $1}'); cur_tx=$(echo "$totals" | awk '{print $2}')
  now=$(date +%s)
  if [ -f "$NET_STATE" ]; then . "$NET_STATE" 2>/dev/null || true; last_t=${LAST_T:-0}; last_rx=${LAST_RX:-0}; last_tx=${LAST_TX:-0}
  else last_t=0; last_rx=0; last_tx=0; fi
  printf 'LAST_T=%s\nLAST_RX=%s\nLAST_TX=%s\n' "$now" "$cur_rx" "$cur_tx" >"$NET_STATE"
  dt=$((now - last_t)); [ $dt -le 0 ] && dt=1
  awk -v a="$last_rx" -v b="$cur_rx" -v c="$last_tx" -v d="$cur_tx" -v dt="$dt" \
    'BEGIN{ rx=(b-a)/dt; tx=(d-c)/dt; if(rx<0)rx=0; if(tx<0)tx=0; printf "%.2f %.2f", rx/1024/1024, tx/1024/1024 }'
}

collect() {
  hostname_v=$(hostname 2>/dev/null || uname -n)
  kernel=$(uname -r 2>/dev/null); arch=$(uname -m 2>/dev/null)
  cores=$(safe_int "$(sysctl -n hw.logicalcpu 2>/dev/null)"); [ "$cores" -gt 0 ] || cores=1
  cpu_model=$(sysctl -n machdep.cpu.brand_string 2>/dev/null); [ -n "$cpu_model" ] || cpu_model="Apple Silicon"
  prod=$(sw_vers -productName 2>/dev/null); ver=$(sw_vers -productVersion 2>/dev/null)
  os_name="${prod:-macOS} ${ver:-}"
  tram=$(total_ram); priv=$(private_ip); pub=$(public_ip); up=$(uptime_human)
  cpu=$(safe_number "$(cpu_usage)"); ram=$(safe_number "$(ram_usage)")
  disk=$(safe_number "$(disk_root)"); tdisk=$(total_disk); [ -n "$tdisk" ] || tdisk="0 GB"
  set -- $(load_avg); l1=$(safe_number "$1"); l5=$(safe_number "$2"); l15=$(safe_number "$3")
  set -- $(net_io); net_in=$(safe_number "$1"); net_out=$(safe_number "$2")
  # macOS no expone uso por núcleo en shell puro; omitimos el campo.
  gpu=$(system_profiler SPDisplaysDataType 2>/dev/null | awk -F': ' '/Chipset Model/{print $2; exit}')
  [ -n "$gpu" ] || gpu="Apple GPU"
  motherboard=$(sysctl -n hw.model 2>/dev/null); [ -n "$motherboard" ] || motherboard="Apple"
  mac_addr=$(ifconfig 2>/dev/null | awk '/^[a-z]/{iface=$1; sub(":","",iface)} /ether/{if(iface!="lo0") printf "%s%s=%s", (n++?",":""), iface, $2}')
  latency_ms=$(ping -c 1 -W 1000 1.1.1.1 2>/dev/null | awk -F'time=' '/time=/{split($2,t," "); printf "%d", t[1]+0.5; exit}')
  case "$latency_ms" in ''|*[!0-9]*) latency_ms=0 ;; esac
  cat <<EOF
{"hostname":"$(json_escape "$hostname_v")","os":"$(json_escape "$os_name")","kernel":"$(json_escape "$kernel")","arch":"$(json_escape "$arch")","cores":$cores,"cpu_model":"$(json_escape "$cpu_model")","total_ram":"$(json_escape "$tram")","total_disk":"$(json_escape "$tdisk")","public_ip":"$(json_escape "$pub")","private_ip":"$(json_escape "$priv")","uptime":"$(json_escape "$up")","cpu":$cpu,"ram":$ram,"disk":$disk,"network_in":$net_in,"network_out":$net_out,"load_avg":{"1":$l1,"5":$l5,"15":$l15},"gpu":"$(json_escape "$gpu")","motherboard":"$(json_escape "$motherboard")","mac_address":"$(json_escape "$mac_addr")","latency_ms":$latency_ms,"agent_version":"$AGENT_VERSION"}
EOF
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
      printf "{\"device\":\"%s\",\"mountpoint\":\"%s\",\"fstype\":\"apfs\",\"total_bytes\":%d,\"used_bytes\":%d,\"free_bytes\":%d,\"use_percent\":%s}", device,mp,total,used,free,(pct+0)
    }
    END{printf "]"}'
}

# -------------------------- Aplicaciones (uso) --------------------------
APPS_STATE_DIR="${TMPDIR:-/tmp}/torobyte-apps"
mkdir -p "$APPS_STATE_DIR" 2>/dev/null || true
APP_LAST_SAMPLE_FILE="$APPS_STATE_DIR/last-sample"

console_user() { stat -f %Su /dev/console 2>/dev/null | tr -d '\n'; }

foreground_app() {
  cu=$(console_user)
  [ -n "$cu" ] && [ "$cu" != "root" ] || return 0
  uid=$(id -u "$cu" 2>/dev/null || echo "")
  if [ -n "$uid" ] && command -v launchctl >/dev/null 2>&1; then
    launchctl asuser "$uid" sudo -u "$cu" osascript -e 'tell application "System Events" to name of first application process whose frontmost is true' 2>/dev/null && return 0
  fi
  sudo -u "$cu" osascript -e 'tell application "System Events" to name of first application process whose frontmost is true' 2>/dev/null || true
}

open_apps() {
  cu=$(console_user)
  uid=$(id -u "$cu" 2>/dev/null || echo "")
  {
    if [ -n "$uid" ] && command -v launchctl >/dev/null 2>&1; then
      launchctl asuser "$uid" sudo -u "$cu" osascript -e 'tell application "System Events" to get name of every application process whose background only is false' 2>/dev/null | tr ',' '\n' | sed 's/^ *//;s/ *$//'
    fi
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
sample_delta() { now=$(date +%s); last=0; [ -f "$APP_LAST_SAMPLE_FILE" ] && last=$(cat "$APP_LAST_SAMPLE_FILE" 2>/dev/null | tr -cd 0-9); echo "$now" > "$APP_LAST_SAMPLE_FILE" 2>/dev/null || true; if [ -z "$last" ] || [ "$last" -le 0 ]; then delta="${INTERVAL:-5}"; else delta=$((now-last)); fi; [ "$delta" -lt 1 ] && delta=1; [ "$delta" -gt 300 ] && delta=300; printf '%s' "$delta"; }
bump() { f="$1"; delta="$2"; cur=0; [ -f "$f" ] && cur=$(cat "$f" 2>/dev/null | tr -cd 0-9); [ -z "$cur" ] && cur=0; echo $((cur + delta)) > "$f"; }
touch_seen() { day="$1"; kind="$2"; name="$3"; nowiso="$4"; label="${5:-$3}"; fs="$APPS_STATE_DIR/$day.first.$kind.$name"; ls_="$APPS_STATE_DIR/$day.last.$kind.$name"; lb="$APPS_STATE_DIR/$day.label.$name"; [ -f "$fs" ] || echo "$nowiso" > "$fs"; echo "$nowiso" > "$ls_"; [ -f "$lb" ] || printf '%s' "$label" > "$lb"; }

sample_apps() {
  day=$(date -u +%Y-%m-%d); nowiso=$(now_iso)
  delta=$(sample_delta)
  fg=$(foreground_app 2>/dev/null || true)
  if [ -n "$fg" ]; then safe=$(app_key "$fg"); [ -n "$safe" ] && bump "$APPS_STATE_DIR/$day.active.$safe" "$delta"; [ -n "$safe" ] && touch_seen "$day" "active" "$safe" "$nowiso" "$fg"; fi
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
    [ -f "$APPS_STATE_DIR/$day.open.$n" ] && open=$(cat "$APPS_STATE_DIR/$day.open.$n" 2>/dev/null | tr -cd 0-9)
    for k in active open; do f="$APPS_STATE_DIR/$day.first.$k.$n"; [ -f "$f" ] && { fs=$(cat "$f" 2>/dev/null); break; }; done
    for k in active open; do l="$APPS_STATE_DIR/$day.last.$k.$n"; [ -f "$l" ] && ls_=$(cat "$l" 2>/dev/null); done
    [ "$first" = "1" ] || printf ','; first=0
    printf '{"key":"%s","label":"%s","source":"gui","seconds_active":%s,"seconds_open":%s,"first_seen":"%s","last_seen":"%s"}' "$(json_escape "$n")" "$(json_escape "$label")" "${active:-0}" "${open:-0}" "$(json_escape "$fs")" "$(json_escape "$ls_")"
  done
  printf ']}'
}

send_apps() {
  BODY=$(build_apps_body) || return 0
  post_json "$APPS_URL" "$BODY" >/dev/null 2>&1 || return 0
  day=$(date -u +%Y-%m-%d)
  rm -f "$APPS_STATE_DIR/$day.active."* "$APPS_STATE_DIR/$day.open."* 2>/dev/null || true
}

encrypt_payload() {
  command -v openssl >/dev/null 2>&1 || { printf ""; return 1; }
  printf '%s' "$1" | openssl enc -aes-256-cbc -pbkdf2 -iter 10000 -salt -base64 -A -pass "pass:$AGENT_TOKEN" 2>/dev/null
}

post_json() {
  url="$1"; body="$2"
  enc=$(encrypt_payload "$body" 2>/dev/null || true)
  if [ -n "$enc" ]; then
    HTTP=$(curl -sS --connect-timeout 10 --max-time 20 -o "$RESP_FILE" -w "%{http_code}" -X POST "$url" \
      -H "Content-Type: text/plain" -H "X-Encrypted: aes-256-cbc-pbkdf2" \
      -H "Authorization: Bearer $AGENT_TOKEN" --data "$enc") || \
    HTTP=$(curl -sS --tlsv1.2 --connect-timeout 10 --max-time 20 -o "$RESP_FILE" -w "%{http_code}" -X POST "$url" \
      -H "Content-Type: text/plain" -H "X-Encrypted: aes-256-cbc-pbkdf2" \
      -H "Authorization: Bearer $AGENT_TOKEN" --data "$enc") || \
    HTTP=$(curl -sSk --connect-timeout 10 --max-time 20 -o "$RESP_FILE" -w "%{http_code}" -X POST "$url" \
      -H "Content-Type: text/plain" -H "X-Encrypted: aes-256-cbc-pbkdf2" \
      -H "Authorization: Bearer $AGENT_TOKEN" --data "$enc") || HTTP="000"
  else
    HTTP=$(curl -sS --connect-timeout 10 --max-time 20 -o "$RESP_FILE" -w "%{http_code}" -X POST "$url" \
      -H "Content-Type: application/json" -H "Authorization: Bearer $AGENT_TOKEN" --data "$body") || \
    HTTP=$(curl -sS --tlsv1.2 --connect-timeout 10 --max-time 20 -o "$RESP_FILE" -w "%{http_code}" -X POST "$url" \
      -H "Content-Type: application/json" -H "Authorization: Bearer $AGENT_TOKEN" --data "$body") || \
    HTTP=$(curl -sSk --connect-timeout 10 --max-time 20 -o "$RESP_FILE" -w "%{http_code}" -X POST "$url" \
      -H "Content-Type: application/json" -H "Authorization: Bearer $AGENT_TOKEN" --data "$body") || HTTP="000"
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
DISKS_URL=$(derive_ingest_url disks)
APPS_URL=$(derive_ingest_url apps)
trap 'rm -f "$RESP_FILE"' EXIT
echo "[$(now_iso)] torobyte-agent (arm64) $AGENT_VERSION started interval=${INTERVAL}s"

AGENT_BASE_VERSION=$(printf '%s' "$AGENT_VERSION" | sed 's/-.*$//')
case "$INGEST_URL" in
  *functions.supabase.co/ingest-metrics*) SELF_UPDATE_URL="https://project--de5cadf8-756e-4d2f-8f8b-6ca62009361b-dev.lovable.app/api/public/agents/macos-arm64.sh" ;;
  *) SELF_UPDATE_URL=$(printf '%s' "$INGEST_URL" | sed 's|/api/public/ingest/metrics.*|/api/public/agents/macos-arm64.sh|') ;;
esac

check_self_update() {
  [ -s "$RESP_FILE" ] || return 0
  UPDATE_TO=$(grep -o '"update_to":"[^"]*"' "$RESP_FILE" 2>/dev/null | head -1 | sed 's/.*:"//;s/"$//')
  [ -n "$UPDATE_TO" ] && [ "$UPDATE_TO" != "null" ] || return 0
  [ "$UPDATE_TO" = "$AGENT_BASE_VERSION" ] && return 0
  echo "[$(now_iso)] update_to=$UPDATE_TO solicitada — reinstalando agente"
  TMP_NEW="/tmp/torobyte-agent.new.$$"
  if curl -fsSL "$SELF_UPDATE_URL" -o "$TMP_NEW" || curl -fsSLk "$SELF_UPDATE_URL" -o "$TMP_NEW"; then
    AGENT_TOKEN="$AGENT_TOKEN" INGEST_URL="$INGEST_URL" INTERVAL="$INTERVAL" /bin/sh "$TMP_NEW" install >>"$LOG_PATH" 2>&1 &
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

while true; do
  BODY=$(collect)
  if post_json "$INGEST_URL" "$BODY"; then
    echo "[$(now_iso)] metrics ok"
    check_self_update
    apply_interval
  fi
  [ "$ONCE" = "1" ] && exit 0
  DISKS=$(collect_disks 2>/dev/null || echo "[]")
  post_json "$DISKS_URL" "{\"disks\":$DISKS}" >/dev/null 2>&1 || true
  sample_apps 2>/dev/null || true
  send_apps 2>/dev/null || true
  sleep "$INTERVAL"
done
