#!/bin/sh
# Torobyte Monitor Cloud - Linux agent
# Usage: AGENT_TOKEN=xxxx INGEST_URL=https://<host>/api/public/ingest/metrics ./linux.sh
set -u

AGENT_TOKEN="${AGENT_TOKEN:-${TOKEN:-}}"
INGEST_URL="${INGEST_URL:-${URL:-}}"
INTERVAL="${INTERVAL:-5}"
ONCE="${ONCE:-0}"
AGENT_VERSION="2.0.1-linux"
MODE="${1:-run}"

step() { printf "\033[1;36m[%s/%s]\033[0m %s\n" "$1" "$2" "$3"; }
ok()   { printf "      \033[1;32m✓\033[0m %s\n" "$1"; }
fail() { printf "      \033[1;31m✗\033[0m %s\n" "$1" >&2; exit 1; }

if [ "$MODE" = "install-service" ] || [ "$MODE" = "install" ]; then
  TOTAL=7
  printf "\n\033[1m🛠  Torobyte Monitor Agent — Instalación %s\033[0m\n\n" "$AGENT_VERSION"

  step 1 $TOTAL "Validando parámetros..."
  [ -n "$AGENT_TOKEN" ] || fail "AGENT_TOKEN (o TOKEN) requerido"
  [ -n "$INGEST_URL" ] || fail "INGEST_URL (o URL) requerido"
  ok "token=${AGENT_TOKEN%${AGENT_TOKEN#????????}}…  url=$INGEST_URL"

  step 2 $TOTAL "Comprobando dependencias (curl)..."
  command -v curl >/dev/null 2>&1 || fail "curl no está instalado"
  ok "curl $(curl --version | head -n1 | awk '{print $2}')"

  step 3 $TOTAL "Detectando init del sistema..."
  if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
    INIT=systemd; ok "systemd detectado"
  else
    INIT=nohup; ok "systemd no disponible — se usará nohup"
  fi

  step 4 $TOTAL "Preparando agente en /usr/local/bin/torobyte-agent.sh ..."
  if [ -r "$0" ] && head -n 1 "$0" 2>/dev/null | grep -q '^#!/bin/sh'; then
    cp "$0" /usr/local/bin/torobyte-agent.sh || fail "no se pudo copiar el instalador local"
    ok "copiado desde instalador local (sin nueva descarga)"
  else
    AGENT_SCRIPT_URL="${AGENT_SCRIPT_URL:-$(printf '%s' "$INGEST_URL" | sed 's|/api/public/ingest/metrics.*|/api/public/agents/linux.sh|')}"
    curl -fsSL --connect-timeout 8 --max-time 40 "$AGENT_SCRIPT_URL" -o /usr/local/bin/torobyte-agent.sh || \
      curl -fsSL --tlsv1.2 --connect-timeout 8 --max-time 40 "$AGENT_SCRIPT_URL" -o /usr/local/bin/torobyte-agent.sh || \
      curl -fsSLk --connect-timeout 8 --max-time 40 "$AGENT_SCRIPT_URL" -o /usr/local/bin/torobyte-agent.sh || \
      fail "no se pudo descargar $AGENT_SCRIPT_URL"
  fi
  head -n 1 /usr/local/bin/torobyte-agent.sh | grep -q '^#!/bin/sh' || fail "la descarga no es un script válido"
  chmod +x /usr/local/bin/torobyte-agent.sh
  ok "$(wc -c </usr/local/bin/torobyte-agent.sh) bytes"

  step 5 $TOTAL "Enviando primera métrica de prueba..."
  if AGENT_TOKEN="$AGENT_TOKEN" INGEST_URL="$INGEST_URL" ONCE=1 /bin/sh /usr/local/bin/torobyte-agent.sh >/tmp/torobyte-first.log 2>&1; then
    ok "ingesta verificada — el servidor pasará a 'en línea'"
  else
    cat /tmp/torobyte-first.log >&2
    fail "no se pudo enviar la primera métrica (revisa token/URL/firewall)"
  fi

  step 6 $TOTAL "Registrando servicio en arranque..."
  if [ "$INIT" = "systemd" ]; then
    cat >/etc/systemd/system/torobyte-agent.service <<EOF
[Unit]
Description=Torobyte Monitor Agent
After=network-online.target
[Service]
Environment=AGENT_TOKEN=$AGENT_TOKEN
Environment=INGEST_URL=$INGEST_URL
Environment=INTERVAL=$INTERVAL
ExecStart=/bin/sh /usr/local/bin/torobyte-agent.sh
Restart=always
RestartSec=10
StandardOutput=append:/var/log/torobyte-agent.log
StandardError=append:/var/log/torobyte-agent.log
[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload >/dev/null 2>&1
    systemctl enable torobyte-agent >/dev/null 2>&1
    systemctl restart torobyte-agent
    ok "servicio systemd habilitado (torobyte-agent)"
  else
    pkill -f /usr/local/bin/torobyte-agent.sh 2>/dev/null || true
    AGENT_TOKEN="$AGENT_TOKEN" INGEST_URL="$INGEST_URL" INTERVAL="$INTERVAL" \
      nohup /bin/sh /usr/local/bin/torobyte-agent.sh >>/var/log/torobyte-agent.log 2>&1 &
    ok "proceso en background pid=$!"
  fi

  step 7 $TOTAL "Verificando estado..."
  sleep 2
  if [ "$INIT" = "systemd" ]; then
    if systemctl is-active --quiet torobyte-agent; then
      ok "servicio activo"
    else
      systemctl --no-pager -l status torobyte-agent | head -n 20 >&2
      fail "el servicio no quedó activo"
    fi
  else
    pgrep -f /usr/local/bin/torobyte-agent.sh >/dev/null && ok "agente en ejecución" || fail "no se encontró el proceso"
  fi

  printf "\n\033[1;32m✔ Instalación completada\033[0m  ·  logs: /var/log/torobyte-agent.log\n"
  printf "   ver en vivo:  tail -f /var/log/torobyte-agent.log\n\n"
  exit 0
fi

if [ "$MODE" = "uninstall" ] || [ "$MODE" = "remove" ]; then
  printf "\n\033[1m🗑  Torobyte Monitor Agent — Desinstalación\033[0m\n\n"
  if command -v systemctl >/dev/null 2>&1; then
    systemctl disable --now torobyte-agent >/dev/null 2>&1 || true
    rm -f /etc/systemd/system/torobyte-agent.service
    systemctl daemon-reload >/dev/null 2>&1 || true
    ok "servicio systemd eliminado"
  fi
  pkill -f /usr/local/bin/torobyte-agent.sh 2>/dev/null || true
  ok "procesos detenidos"
  rm -f /usr/local/bin/torobyte-agent.sh
  rm -f /var/log/torobyte-agent.log /tmp/torobyte-first.log /tmp/torobyte-agent.*.resp
  ok "archivos eliminados"
  printf "\n\033[1;32m✔ Agente desinstalado del host\033[0m\n"
  printf "   Recuerda eliminar el servidor también desde la plataforma si ya no lo necesitas.\n\n"
  exit 0
fi
RESP_FILE="${TMPDIR:-/tmp}/torobyte-agent.$$.resp"

case "$INTERVAL" in ''|*[!0-9]*) INTERVAL=5 ;; esac
[ "$INTERVAL" -lt 5 ] && INTERVAL=5

if [ -z "$AGENT_TOKEN" ] || [ -z "$INGEST_URL" ]; then
  echo "AGENT_TOKEN and INGEST_URL are required" >&2
  exit 1
fi
if ! command -v curl >/dev/null 2>&1; then
  echo "curl is required to run the Torobyte agent" >&2
  exit 1
fi

json_escape() {
  printf '%s' "${1:-}" | tr '\n' ' ' | awk 'BEGIN{ORS=""}{gsub(/\\/,"\\\\"); gsub(/"/,"\\\""); gsub(/\r/,"\\r"); gsub(/\t/,"\\t"); print}'
}

safe_number() {
  awk -v v="${1:-0}" 'BEGIN{if (v ~ /^-?[0-9]+([.][0-9]+)?$/) printf "%s", v+0; else printf "0"}'
}

safe_int() {
  awk -v v="${1:-0}" 'BEGIN{if (v ~ /^[0-9]+$/) printf "%d", v; else printf "0"}'
}

now_iso() {
  date -Is 2>/dev/null || date '+%Y-%m-%dT%H:%M:%S%z'
}

CPU_STATE="${TMPDIR:-/tmp}/torobyte-cpu.state"
cpu_sample() {
  # Imprime "total idle\ncpu0 user nice sys idle iowait irq softirq steal\ncpu1 ..."
  awk '/^cpu[0-9]* /' /proc/stat 2>/dev/null
}
cpu_compute() {
  # Devuelve "TOTAL_PCT;c0,c1,c2,..." comparando con CPU_STATE; si no hay previo, snapshot ahora, sleep 1, snapshot otra vez.
  if [ -r "$CPU_STATE" ]; then
    prev=$(cat "$CPU_STATE")
    now=$(cpu_sample)
  else
    prev=$(cpu_sample); sleep 1; now=$(cpu_sample)
  fi
  printf '%s' "$now" >"$CPU_STATE" 2>/dev/null
  printf '%s\n---\n%s\n' "$prev" "$now" | awk '
    BEGIN{stage=0; n1=0; n2=0}
    /^---$/ {stage=1; next}
    stage==0 { a[n1]=$0; n1++; next }
    stage==1 { b[n2]=$0; n2++; next }
    END{
      total_pct=0
      cores=""
      for(i=0;i<n1 && i<n2;i++){
        split(a[i], p, " "); split(b[i], q, " ")
        # p[1]=cpu  p[2]=user p[3]=nice p[4]=sys p[5]=idle p[6]=iowait p[7]=irq p[8]=softirq p[9]=steal
        idle1=p[5]+p[6]; idle2=q[5]+q[6]
        tot1=p[2]+p[3]+p[4]+p[5]+p[6]+p[7]+p[8]+p[9]
        tot2=q[2]+q[3]+q[4]+q[5]+q[6]+q[7]+q[8]+q[9]
        dt=tot2-tot1; di=idle2-idle1
        pct = (dt>0)? (dt-di)*100/dt : 0
        if(pct<0) pct=0; if(pct>100) pct=100
        if(i==0){ total_pct=pct; continue }
        if(cores!="") cores = cores ","
        cores = cores sprintf("%.1f", pct)
      }
      printf "%.1f;[%s]", total_pct, cores
    }'
}
cpu_usage() {
  cpu_compute | awk -F';' '{print $1}'
}
cpu_cores_json() {
  cpu_compute | awk -F';' '{print $2}'
}

private_ip() {
  ip_addr=$(hostname -I 2>/dev/null | awk '{print $1}')
  [ -n "$ip_addr" ] || ip_addr=$(ip -4 -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1)
  [ -n "$ip_addr" ] || ip_addr=$(ifconfig 2>/dev/null | awk '/inet / && $2 != "127.0.0.1" {print $2; exit}' | sed 's/^addr://')
  printf '%s' "$ip_addr"
}

collect() {
  hostname_v=$(hostname 2>/dev/null || uname -n 2>/dev/null || echo unknown)
  kernel=$(uname -r 2>/dev/null || echo unknown)
  arch=$(uname -m 2>/dev/null || echo unknown)
  cores=$(nproc 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1)
  cores=$(safe_int "$cores")
  [ "$cores" -gt 0 ] || cores=1
  cpu_model=$(awk -F': ' '/^model name/ {print $2; exit}' /proc/cpuinfo 2>/dev/null)
  [ -n "$cpu_model" ] || cpu_model=$(awk -F': ' '/^Hardware|^Processor|^cpu model/ {print $2; exit}' /proc/cpuinfo 2>/dev/null)
  [ -n "$cpu_model" ] || cpu_model=$(lscpu 2>/dev/null | awk -F': +' '/Model name/ {print $2; exit}')
  [ -n "$cpu_model" ] || cpu_model="CPU desconocida"

  if [ -r /etc/os-release ]; then
    os_name=$(. /etc/os-release && echo "${PRETTY_NAME:-${NAME:-Linux}}")
  else
    os_name=$(uname -s 2>/dev/null || echo Linux)
  fi

  total_ram=$(awk '/MemTotal/ {printf "%.1f GB", $2/1024/1024}' /proc/meminfo 2>/dev/null)
  [ -n "$total_ram" ] || total_ram="0 GB"
  priv_ip=$(private_ip)
  pub_ip=$(curl -fsS --connect-timeout 2 --max-time 4 https://api.ipify.org 2>/dev/null || echo "")
  uptime_v=$(uptime -p 2>/dev/null | sed 's/^up //')
  [ -n "$uptime_v" ] || uptime_v=$(awk '{printf "%d s", $1}' /proc/uptime 2>/dev/null || echo "0 s")

  cpu_data=$(cpu_compute)
  cpu=$(safe_number "$(printf '%s' "$cpu_data" | awk -F';' '{print $1}')")
  cpu_cores_arr=$(printf '%s' "$cpu_data" | awk -F';' '{print $2}')
  [ -n "$cpu_cores_arr" ] || cpu_cores_arr="[]"
  ram=$(safe_number "$(awk '/MemTotal/{t=$2} /MemAvailable/{a=$2} END{if(t>0) printf "%.1f", (t-a)*100/t; else print 0}' /proc/meminfo 2>/dev/null)")
  disk=$(safe_number "$(df -P / 2>/dev/null | awk 'NR==2 {gsub("%","",$5); print $5+0}')")
  total_disk=$(df -BK -P / 2>/dev/null | awk 'NR==2 {kb=$2; gsub("K","",kb); gb=kb/1024/1024; if(gb>=1024) printf "%.2f TB", gb/1024; else printf "%.1f GB", gb}')
  [ -n "$total_disk" ] || total_disk="0 GB"
  l1=$(safe_number "$(awk '{print $1}' /proc/loadavg 2>/dev/null)")
  l5=$(safe_number "$(awk '{print $2}' /proc/loadavg 2>/dev/null)")
  l15=$(safe_number "$(awk '{print $3}' /proc/loadavg 2>/dev/null)")

  rx1=$(awk '/:/ && !/lo:/ {sum+=$2} END{print sum+0}' /proc/net/dev 2>/dev/null)
  tx1=$(awk '/:/ && !/lo:/ {sum+=$10} END{print sum+0}' /proc/net/dev 2>/dev/null)
  sleep 1
  rx2=$(awk '/:/ && !/lo:/ {sum+=$2} END{print sum+0}' /proc/net/dev 2>/dev/null)
  tx2=$(awk '/:/ && !/lo:/ {sum+=$10} END{print sum+0}' /proc/net/dev 2>/dev/null)
  net_in=$(awk -v a="${rx1:-0}" -v b="${rx2:-0}" 'BEGIN{d=b-a; if(d<0)d=0; printf "%.2f", d/1024/1024}')
  net_out=$(awk -v a="${tx1:-0}" -v b="${tx2:-0}" 'BEGIN{d=b-a; if(d<0)d=0; printf "%.2f", d/1024/1024}')

  gpu=$(lspci 2>/dev/null | grep -iE 'vga|3d|display' | head -1 | sed 's/^[^:]*: //;s/ (rev .*//')
  [ -n "$gpu" ] || gpu=$(ls /sys/class/drm/ 2>/dev/null | grep -E '^card[0-9]+$' | head -1)
  [ -n "$gpu" ] || gpu="GPU desconocida"
  mb_vendor=$(cat /sys/devices/virtual/dmi/id/board_vendor 2>/dev/null | tr -d '\n')
  mb_name=$(cat /sys/devices/virtual/dmi/id/board_name 2>/dev/null | tr -d '\n')
  motherboard=$(printf '%s %s' "$mb_vendor" "$mb_name" | sed 's/^ *//;s/ *$//')
  [ -n "$motherboard" ] || motherboard="Desconocida"
  mac_addr=$(for f in /sys/class/net/*/address; do
      iface=$(basename $(dirname $f))
      case "$iface" in lo|docker*|veth*|br-*|virbr*|tun*|tap*) continue ;; esac
      mac=$(cat "$f" 2>/dev/null)
      [ "$mac" = "00:00:00:00:00:00" ] && continue
      [ -n "$mac" ] && printf '%s=%s\n' "$iface" "$mac"
    done | paste -sd ',' -)
  [ -n "$mac_addr" ] || mac_addr=""

  latency_ms=$(ping -c 1 -W 1 1.1.1.1 2>/dev/null | awk -F'time=' '/time=/{split($2,t," "); printf "%d", t[1]+0.5; exit}')
  case "$latency_ms" in ''|*[!0-9]*) latency_ms=0 ;; esac

  cat <<EOF
{"hostname":"$(json_escape "$hostname_v")","os":"$(json_escape "$os_name")","kernel":"$(json_escape "$kernel")","arch":"$(json_escape "$arch")","cores":$cores,"cpu_model":"$(json_escape "$cpu_model")","total_ram":"$(json_escape "$total_ram")","total_disk":"$(json_escape "$total_disk")","public_ip":"$(json_escape "$pub_ip")","private_ip":"$(json_escape "$priv_ip")","uptime":"$(json_escape "$uptime_v")","cpu":$cpu,"cpu_cores":$cpu_cores_arr,"ram":$ram,"disk":$disk,"network_in":$net_in,"network_out":$net_out,"load_avg":{"1":$l1,"5":$l5,"15":$l15},"gpu":"$(json_escape "$gpu")","motherboard":"$(json_escape "$motherboard")","mac_address":"$(json_escape "$mac_addr")","latency_ms":$latency_ms,"agent_version":"$AGENT_VERSION"}
EOF
}

collect_processes() {
  ps -eo pid=,user=,pcpu=,pmem=,rss=,comm=,args= --sort=-pcpu 2>/dev/null | head -n 200 | awk '
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
  if command -v ss >/dev/null 2>&1; then
    ss -tulnHp 2>/dev/null | awk '
      BEGIN{printf "["; first=1}
      {
        proto=$1; local=$5; users=""; for(i=7;i<=NF;i++)users=users $i;
        n=split(local,a,":"); port=a[n]; addr=local; sub(":"port"$","",addr);
        pname=""; pid="";
        if(match(users,/"[^"]+"/)){pname=substr(users,RSTART+1,RLENGTH-2)}
        if(match(users,/pid=[0-9]+/)){pid=substr(users,RSTART+4,RLENGTH-4)}
        gsub(/\\/,"\\\\",pname); gsub(/"/,"\\\"",pname);
        gsub(/\\/,"\\\\",addr); gsub(/"/,"\\\"",addr);
        if(port+0<=0)next;
        if(!first)printf ","; first=0;
        printf "{\"protocol\":\"%s\",\"port\":%d,\"address\":\"%s\",\"process\":\"%s\",\"pid\":%s}", proto,port,addr,pname,(pid==""?"null":pid)
      }
      END{printf "]"}'
  elif command -v netstat >/dev/null 2>&1; then
    netstat -tulnp 2>/dev/null | awk 'NR>2{
      proto=$1; local=$4; prog=$NF;
      n=split(local,a,":"); port=a[n]; addr=local; sub(":"port"$","",addr);
      split(prog,pp,"/"); pid=pp[1]; pname=pp[2];
      if(port+0<=0)next;
      printf (NR==3?"":",") "{\"protocol\":\"%s\",\"port\":%d,\"address\":\"%s\",\"process\":\"%s\",\"pid\":%s}", proto,port,addr,pname,(pid~/^[0-9]+$/?pid:"null")
    } BEGIN{printf "["} END{printf "]"}'
  else
    printf "[]"
  fi
}

collect_disks() {
  df -PT -B1 2>/dev/null | awk '
    BEGIN{printf "["; first=0}
    NR==1 {next}
    {
      fstype=$2
      if (fstype ~ /^(tmpfs|devtmpfs|overlay|squashfs|aufs|proc|sysfs|cgroup|cgroup2|devpts|mqueue|nsfs|pstore|bpf|tracefs|debugfs|securityfs|configfs|fusectl|autofs|ramfs|rpc_pipefs|binfmt_misc)$/) next
      device=$1; total=$3+0; used=$4+0; free=$5+0; pct=$6; gsub("%","",pct); mp=$7
      if (total<=0) next
      gsub(/\\/,"\\\\",device); gsub(/"/,"\\\"",device)
      gsub(/\\/,"\\\\",mp); gsub(/"/,"\\\"",mp)
      gsub(/\\/,"\\\\",fstype); gsub(/"/,"\\\"",fstype)
      if (first) printf ","; first=1
      printf "{\"device\":\"%s\",\"mountpoint\":\"%s\",\"fstype\":\"%s\",\"total_bytes\":%d,\"used_bytes\":%d,\"free_bytes\":%d,\"use_percent\":%s}", device,mp,fstype,total,used,free,(pct+0)
    }
    END{printf "]"}'
}

collect_services() {
  if ! command -v systemctl >/dev/null 2>&1; then
    printf "[]"; return
  fi
  systemctl list-units --type=service --all --no-legend --no-pager --plain 2>/dev/null | awk '
    BEGIN{printf "["; first=1}
    {
      name=$1; load=$2; active=$3; sub_st=$4;
      desc="";
      for(i=5;i<=NF;i++) desc=desc (i==5?"":" ") $i;
      if (name=="" || name ~ /\.scope$/ || name ~ /\.slice$/ || name ~ /\.target$/) next;
      status=(active=="active")?"running":(active=="failed")?"failed":(active=="inactive"||active=="dead")?"stopped":active;
      gsub(/\\/,"\\\\",name); gsub(/"/,"\\\"",name);
      gsub(/\\/,"\\\\",desc); gsub(/"/,"\\\"",desc);
      gsub(/\\/,"\\\\",sub_st); gsub(/"/,"\\\"",sub_st);
      if(!first) printf ","; first=0;
      printf "{\"name\":\"%s\",\"display_name\":\"%s\",\"status\":\"%s\",\"type\":\"systemd\"}", name, desc, status;
    }
    END{printf "]"}'
}

encrypt_payload() {
  # Cifra el cuerpo con AES-256-CBC + PBKDF2 (SHA-256, 10k iters) usando el token
  # como passphrase, formato OpenSSL "Salted__" base64. El servidor descifra
  # con el mismo agent_token (que ya conoce).
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
      -H "Content-Type: application/json" \
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

trap 'rm -f "$RESP_FILE"' EXIT
echo "[$(now_iso)] torobyte-agent $AGENT_VERSION started interval=${INTERVAL}s endpoint=${INGEST_URL}"

AGENT_BASE_VERSION=$(printf '%s' "$AGENT_VERSION" | sed 's/-.*$//')
case "$INGEST_URL" in
  *functions.supabase.co/ingest-metrics*) SELF_UPDATE_URL="https://project--de5cadf8-756e-4d2f-8f8b-6ca62009361b-dev.lovable.app/api/public/agents/linux.sh" ;;
  *) SELF_UPDATE_URL=$(printf '%s' "$INGEST_URL" | sed 's|/api/public/ingest/metrics.*|/api/public/agents/linux.sh|') ;;
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
      /bin/sh "$TMP_NEW" install >>/var/log/torobyte-agent.log 2>&1 &
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
  PROCS=$(collect_processes 2>/dev/null || echo "[]")
  post_json "$PROC_URL" "{\"processes\":$PROCS}" >/dev/null 2>&1 || true
  PORTS=$(collect_ports 2>/dev/null || echo "[]")
  post_json "$PORTS_URL" "{\"ports\":$PORTS}" >/dev/null 2>&1 || true
  DISKS=$(collect_disks 2>/dev/null || echo "[]")
  post_json "$DISKS_URL" "{\"disks\":$DISKS}" >/dev/null 2>&1 || true
  SERVICES=$(collect_services 2>/dev/null || echo "[]")
  post_json "$SERVICES_URL" "{\"services\":$SERVICES}" >/dev/null 2>&1 || true

  if [ "$ONCE" = "1" ]; then exit 0; fi
  sleep "$INTERVAL"
done
