#!/bin/sh
# Torobyte Monitor Cloud - Linux agent
# Usage: AGENT_TOKEN=xxxx INGEST_URL=https://<host>/api/public/ingest/metrics ./linux.sh
set -u

AGENT_TOKEN="${AGENT_TOKEN:-${TOKEN:-}}"
INGEST_URL="${INGEST_URL:-${URL:-}}"
INTERVAL="${INTERVAL:-5}"
ONCE="${ONCE:-0}"
AGENT_VERSION="2.3.9-linux"
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
  wifi_aps=$(wifi_aps_json); [ -n "$wifi_aps" ] || wifi_aps="[]"
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

  sys_vendor=$(cat /sys/devices/virtual/dmi/id/sys_vendor 2>/dev/null | tr -d '\n')
  sys_product=$(cat /sys/devices/virtual/dmi/id/product_name 2>/dev/null | tr -d '\n')
  sys_serial=$(cat /sys/devices/virtual/dmi/id/product_serial 2>/dev/null | tr -d '\n')
  [ -n "$sys_serial" ] || sys_serial=$(cat /sys/devices/virtual/dmi/id/board_serial 2>/dev/null | tr -d '\n')
  case "$sys_serial" in "To Be Filled By O.E.M."|"System Serial Number"|"None"|"Default string") sys_serial="" ;; esac
  case "$sys_vendor"  in "To Be Filled By O.E.M."|"System manufacturer"|"None"|"Default string") sys_vendor="" ;; esac
  case "$sys_product" in "To Be Filled By O.E.M."|"System Product Name"|"None"|"Default string") sys_product="" ;; esac

  latency_ms=$(ping -c 1 -W 1 1.1.1.1 2>/dev/null | awk -F'time=' '/time=/{split($2,t," "); printf "%d", t[1]+0.5; exit}')
  case "$latency_ms" in ''|*[!0-9]*) latency_ms=0 ;; esac

  cat <<EOF
{"hostname":"$(json_escape "$hostname_v")","os":"$(json_escape "$os_name")","kernel":"$(json_escape "$kernel")","arch":"$(json_escape "$arch")","cores":$cores,"cpu_model":"$(json_escape "$cpu_model")","total_ram":"$(json_escape "$total_ram")","total_disk":"$(json_escape "$total_disk")","public_ip":"$(json_escape "$pub_ip")","wifi_aps":$wifi_aps,"private_ip":"$(json_escape "$priv_ip")","uptime":"$(json_escape "$uptime_v")","cpu":$cpu,"cpu_cores":$cpu_cores_arr,"ram":$ram,"disk":$disk,"network_in":$net_in,"network_out":$net_out,"load_avg":{"1":$l1,"5":$l5,"15":$l15},"gpu":"$(json_escape "$gpu")","motherboard":"$(json_escape "$motherboard")","mac_address":"$(json_escape "$mac_addr")","manufacturer":"$(json_escape "$sys_vendor")","hw_model":"$(json_escape "$sys_product")","serial_number":"$(json_escape "$sys_serial")","latency_ms":$latency_ms,"agent_version":"$AGENT_VERSION"}
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

collect_programs() {
  {
    if command -v dpkg-query >/dev/null 2>&1; then
      dpkg-query -W -f='${Package}|${Version}|${Maintainer}|${Installed-Size}|dpkg\n' 2>/dev/null
    elif command -v rpm >/dev/null 2>&1; then
      rpm -qa --qf '%{NAME}|%{VERSION}-%{RELEASE}|%{VENDOR}|%{SIZE}|rpm\n' 2>/dev/null
    elif command -v apk >/dev/null 2>&1; then
      apk info -v 2>/dev/null | awk '{print $1"|||0|apk"}'
    fi
  } | awk -F'|' -v arch="$(uname -m)" '
    function esc(s) { gsub(/\\/,"\\\\",s); gsub(/"/,"\\\"",s); return s }
    BEGIN{printf "["; first=1}
    NF>=5 && $1 != "" {
      size="null"
      if ($4 ~ /^[0-9]+$/ && $4+0 > 0) {
        if ($5 == "rpm") size=sprintf("%.1f", $4/1048576); else size=sprintf("%.1f", $4/1024)
      }
      if (!first) printf ","
      first=0
      printf "{\"name\":\"%s\",\"version\":\"%s\",\"publisher\":\"%s\",\"size_mb\":%s,\"arch\":\"%s\",\"source\":\"%s\"}", esc($1), esc($2), esc($3), size, arch, esc($5)
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
SECURITY_URL=$(derive_ingest_url security)
PROGRAMS_URL=$(derive_ingest_url programs)
PROG_LAST=0
PROG_INTERVAL=21600
SEC_INTERVAL="${SEC_INTERVAL:-3600}"
SEC_LAST=0

num() { v=$(printf '%s\n' "${1:-}" | head -n1 | tr -dc '0-9'); [ -n "$v" ] || v=0; printf '%s' "$v"; }
# sint: entero con signo. Permite -1 = desconocido (no confundir con 0).
sint() { v=$(printf '%s\n' "${1:-}" | head -n1 | tr -dc '0-9-'); case "$v" in ""|-) v=-1 ;; esac; printf '%s' "$v"; }

collect_security() {
  OS_NAME=$(. /etc/os-release 2>/dev/null; echo "${PRETTY_NAME:-Linux}")
  OS_VERSION=$(. /etc/os-release 2>/dev/null; echo "${VERSION_ID:-}")
  OS_BUILD=$(uname -r)
  # -1 = desconocido. Nunca se reporta 0 si el gestor de paquetes no respondio.
  PENDING=-1; CRITICAL=-1; LAST_UPDATE=""; UPD_SOURCE="unavailable"
  if command -v apt-get >/dev/null 2>&1; then
    SIM=$(apt-get -s -o Debug::NoLocking=1 dist-upgrade 2>/dev/null || true)
    if [ -n "$SIM" ]; then
      PENDING=$(printf '%s\n' "$SIM" | grep -c '^Inst ')
      CRITICAL=$(printf '%s\n' "$SIM" | grep '^Inst ' | grep -Eic 'security')
      UPD_SOURCE="apt-get-sim"
    else
      UPG=$(apt list --upgradable 2>/dev/null | grep 'upgradable' || true)
      if [ -n "$UPG" ]; then
        PENDING=$(printf '%s\n' "$UPG" | grep -c 'upgradable')
        CRITICAL=$(printf '%s\n' "$UPG" | grep -ic security)
        UPD_SOURCE="apt-list"
      fi
    fi
    LAST_UPDATE=$(stat -c %y /var/lib/apt/periodic/update-success-stamp 2>/dev/null | awk '{print $1"T"$2}' | cut -c1-19)
    [ -n "$LAST_UPDATE" ] || LAST_UPDATE=$(stat -c %y /var/log/dpkg.log 2>/dev/null | awk '{print $1"T"$2}' | cut -c1-19)
  elif command -v dnf >/dev/null 2>&1; then
    OUT=$(dnf -q check-update 2>/dev/null || true)
    PENDING=$(printf '%s\n' "$OUT" | grep -c '^[a-zA-Z]')
    CRITICAL=$(dnf -q updateinfo list security 2>/dev/null | grep -c '/')
    UPD_SOURCE="dnf"
    LAST_UPDATE=$(stat -c %y /var/log/dnf.rpm.log 2>/dev/null | awk '{print $1"T"$2}' | cut -c1-19)
  elif command -v yum >/dev/null 2>&1; then
    OUT=$(yum -q check-update 2>/dev/null || true)
    PENDING=$(printf '%s\n' "$OUT" | grep -c '^[a-zA-Z]')
    CRITICAL=0
    UPD_SOURCE="yum"
  elif command -v zypper >/dev/null 2>&1; then
    PENDING=$(zypper -q list-updates 2>/dev/null | grep -c '^v |')
    CRITICAL=$(zypper -q list-patches --category security 2>/dev/null | grep -c 'security')
    UPD_SOURCE="zypper"
  fi

  # tbool: 3 estados (true/false/null). null = no se pudo determinar.
  tbool() { case "${1:-}" in true|1|yes|on) printf 'true' ;; false|0|no|off) printf 'false' ;; *) printf 'null' ;; esac; }

  # Firewall: se evalúan todos los motores presentes. Si ninguno está
  # instalado el estado es desconocido (null), no "desactivado".
  FW_ENABLED=null
  if command -v ufw >/dev/null 2>&1; then
    UFW_OUT=$(ufw status 2>/dev/null || true)
    printf '%s' "$UFW_OUT" | grep -qi 'Status: active' && FW_ENABLED=true
    printf '%s' "$UFW_OUT" | grep -qi 'Status: inactive' && [ "$FW_ENABLED" != "true" ] && FW_ENABLED=false
  fi
  if [ "$FW_ENABLED" != "true" ] && command -v firewall-cmd >/dev/null 2>&1; then
    FWD_OUT=$(firewall-cmd --state 2>/dev/null || true)
    printf '%s' "$FWD_OUT" | grep -q running && FW_ENABLED=true
    printf '%s' "$FWD_OUT" | grep -q 'not running' && [ "$FW_ENABLED" != "true" ] && FW_ENABLED=false
  fi
  if [ "$FW_ENABLED" != "true" ] && command -v nft >/dev/null 2>&1; then
    NFT_OUT=$(nft list ruleset 2>/dev/null || true)
    if printf '%s' "$NFT_OUT" | grep -q 'chain'; then FW_ENABLED=true; fi
  fi
  if [ "$FW_ENABLED" != "true" ] && command -v iptables >/dev/null 2>&1; then
    IPT_OUT=$(iptables -S 2>/dev/null || true)
    if printf '%s\n' "$IPT_OUT" | grep -qE '^-A ' || printf '%s\n' "$IPT_OUT" | grep -qE '^-P (INPUT|FORWARD) DROP'; then
      FW_ENABLED=true
    elif [ -n "$IPT_OUT" ] && [ "$FW_ENABLED" = "null" ]; then
      FW_ENABLED=false
    fi
  fi

  # Cifrado de disco: LUKS o dm-crypt. Sin herramientas -> desconocido.
  DISK_ENC=null
  if command -v lsblk >/dev/null 2>&1; then
    if lsblk -o TYPE 2>/dev/null | grep -q crypt; then DISK_ENC=true; else DISK_ENC=false; fi
  fi
  if [ "$DISK_ENC" != "true" ]; then
    if [ -s /etc/crypttab ] && grep -qv '^[[:space:]]*#' /etc/crypttab 2>/dev/null; then DISK_ENC=true; fi
    if [ "$DISK_ENC" != "true" ] && command -v dmsetup >/dev/null 2>&1; then
      dmsetup ls --target crypt 2>/dev/null | grep -qv 'No devices' && dmsetup ls --target crypt 2>/dev/null | grep -q '.' && DISK_ENC=true
    fi
  fi

  AV_NAME=""; AV_EN=null; AV_UPD=null
  if command -v clamscan >/dev/null 2>&1 || command -v clamdscan >/dev/null 2>&1 || systemctl list-unit-files 2>/dev/null | grep -q '^clamav-daemon'; then
    AV_NAME="ClamAV"
    if systemctl is-active --quiet clamav-daemon 2>/dev/null || systemctl is-active --quiet clamd@scan 2>/dev/null; then AV_EN=true; else AV_EN=false; fi
    for FL in /var/log/clamav/freshclam.log /var/lib/clamav/daily.cvd /var/lib/clamav/daily.cld; do
      if [ -e "$FL" ]; then
        LAST=$(stat -c %Y "$FL" 2>/dev/null || echo 0)
        NOW=$(date +%s)
        if [ $((NOW - LAST)) -lt 604800 ]; then AV_UPD=true; elif [ "$AV_UPD" != "true" ]; then AV_UPD=false; fi
      fi
    done
  fi
  ADMIN_COUNT=$( { getent group sudo; getent group wheel; getent group admin; } 2>/dev/null | awk -F: '{n=split($4,a,","); for(i=1;i<=n;i++) if(a[i]!="") print a[i]}' | sort -u | wc -l)
  LOCAL_USERS=$(awk -F: '$3>=1000 && $3<65534 && $1!="nobody" {c++} END{print c+0}' /etc/passwd)

  # Puertos: se cuentan puertos únicos en escucha y se adjunta la dirección
  # de escucha de los puertos riesgosos.
  OPEN_PORTS=-1; RISKY_JSON="[]"
  SS_OUT=""
  if command -v ss >/dev/null 2>&1; then
    SS_OUT=$(ss -tulnH 2>/dev/null || ss -tuln 2>/dev/null | awk 'NR>1')
  elif command -v netstat >/dev/null 2>&1; then
    SS_OUT=$(netstat -tuln 2>/dev/null | awk 'NR>2')
  fi
  if [ -n "$SS_OUT" ]; then
    OPEN_PORTS=$(printf '%s\n' "$SS_OUT" | awk '{for(i=1;i<=NF;i++) if($i ~ /:[0-9]+$/){n=split($i,a,":"); print a[n]; break}}' | grep '^[0-9]' | sort -u | wc -l)
    RISKY=$(printf '%s\n' "$SS_OUT" | awk '{addr=""; for(i=1;i<=NF;i++) if($i ~ /:[0-9]+$/){addr=$i; break} if(addr==""){next} n=split(addr,a,":"); port=a[n]; host=substr(addr,1,length(addr)-length(port)-1); if(host=="") host="*"; print port"|"host}' | sort -u | \
      awk -F'|' 'BEGIN{first=1} !seen[$1]++ { p=$1+0; if(p==21||p==23||p==135||p==139||p==445||p==3389||p==5900||p==3306||p==5432||p==6379||p==27017||p==11211||p==1433) { if(!first) printf ","; printf "{\"port\":%d,\"address\":\"%s\",\"protocol\":\"tcp\"}", p, $2; first=0 } }')
    RISKY_JSON="[$RISKY]"
  fi

  SSH_EN=null
  if systemctl list-unit-files 2>/dev/null | grep -qE '^(ssh|sshd)\.(service|socket)'; then
    if systemctl is-active --quiet ssh 2>/dev/null || systemctl is-active --quiet sshd 2>/dev/null || systemctl is-active --quiet ssh.socket 2>/dev/null; then SSH_EN=true; else SSH_EN=false; fi
  elif [ -n "$SS_OUT" ]; then
    if printf '%s\n' "$SS_OUT" | awk '{for(i=1;i<=NF;i++) if($i ~ /:[0-9]+$/){n=split($i,a,":"); print a[n]; break}}' | grep -q '^22$'; then SSH_EN=true; else SSH_EN=false; fi
  fi

  AUDIT_EN=null
  if systemctl list-unit-files 2>/dev/null | grep -q '^auditd'; then
    if systemctl is-active --quiet auditd 2>/dev/null; then AUDIT_EN=true; else AUDIT_EN=false; fi
  elif command -v auditctl >/dev/null 2>&1; then
    auditctl -s 2>/dev/null | grep -q 'enabled 1' && AUDIT_EN=true
  elif [ -d /var/log/journal ] || [ -f /var/log/syslog ] || [ -f /var/log/messages ]; then
    AUDIT_EN=true
  fi

  # Bloqueo de pantalla: sólo aplica a equipos con escritorio gráfico.
  # En servidores headless se reporta desconocido en vez de "desactivado".
  SCREEN_LOCK=null
  if [ -n "$(ls /usr/share/xsessions /usr/share/wayland-sessions 2>/dev/null)" ]; then
    SCREEN_LOCK=false
    if command -v gsettings >/dev/null 2>&1; then
      GSU=$(ls -1 /home 2>/dev/null | head -1)
      GS_OUT=$(gsettings get org.gnome.desktop.screensaver lock-enabled 2>/dev/null || true)
      [ -n "$GS_OUT" ] || GS_OUT=$( [ -n "$GSU" ] && sudo -u "$GSU" gsettings get org.gnome.desktop.screensaver lock-enabled 2>/dev/null || true)
      printf '%s' "$GS_OUT" | grep -q true && SCREEN_LOCK=true
      [ -z "$GS_OUT" ] && SCREEN_LOCK=null
    else
      SCREEN_LOCK=null
    fi
  fi
  PENDING=$(sint "$PENDING"); CRITICAL=$(sint "$CRITICAL")
  ADMIN_COUNT=$(num "$ADMIN_COUNT"); LOCAL_USERS=$(num "$LOCAL_USERS"); OPEN_PORTS=$(sint "$OPEN_PORTS")
  case "$RISKY_JSON" in '['*']') : ;; *) RISKY_JSON="[]" ;; esac
  FW_ENABLED=$(tbool "$FW_ENABLED"); DISK_ENC=$(tbool "$DISK_ENC"); AV_EN=$(tbool "$AV_EN")
  AV_UPD=$(tbool "$AV_UPD"); SSH_EN=$(tbool "$SSH_EN"); AUDIT_EN=$(tbool "$AUDIT_EN")
  SCREEN_LOCK=$(tbool "$SCREEN_LOCK")
  cat <<JSON
{"agent_version":"$AGENT_VERSION","os_name":"$(json_escape "$OS_NAME")","os_version":"$(json_escape "$OS_VERSION")","os_build":"$(json_escape "$OS_BUILD")","os_last_update_at":$( [ -n "$LAST_UPDATE" ] && echo "\"${LAST_UPDATE}Z\"" || echo null ),"updates_source":"$UPD_SOURCE","os_pending_updates":$PENDING,"os_critical_updates":$CRITICAL,"antivirus_name":$( [ -n "$AV_NAME" ] && echo "\"$AV_NAME\"" || echo null ),"antivirus_enabled":$AV_EN,"antivirus_up_to_date":$AV_UPD,"firewall_enabled":$FW_ENABLED,"disk_encryption_enabled":$DISK_ENC,"disk_encryption_method":"LUKS","screen_lock_enabled":$SCREEN_LOCK,"admin_accounts_count":$ADMIN_COUNT,"local_users_count":$LOCAL_USERS,"open_ports_count":$OPEN_PORTS,"risky_open_ports":$RISKY_JSON,"ssh_enabled":$SSH_EN,"rdp_enabled":false,"audit_logging_enabled":$AUDIT_EN}
JSON
}

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
  NEW_SEC=$(grep -o '"security_interval":[0-9]*' "$RESP_FILE" 2>/dev/null | head -1 | sed 's/.*://')
  case "$NEW_SEC" in ''|*[!0-9]*) : ;; *) [ "$NEW_SEC" -ge 15 ] && SEC_INTERVAL="$NEW_SEC" ;; esac
  # Solicitud manual de auditoría de seguridad desde la plataforma
  if grep -q '"security_now":true' "$RESP_FILE" 2>/dev/null; then SEC_LAST=0; fi
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
  PROG_NOW=$(date +%s)
  if [ "$((PROG_NOW - PROG_LAST))" -ge "$PROG_INTERVAL" ]; then
    PROGRAMS=$(collect_programs 2>/dev/null || echo "[]")
    case "$PROGRAMS" in
      '[]'|'') : ;;
      *) if post_json "$PROGRAMS_URL" "{\"programs\":$PROGRAMS}" >/dev/null 2>&1; then PROG_LAST=$PROG_NOW; fi ;;
    esac
  fi

  NOW_TS=$(date +%s)
  if [ "$((NOW_TS - SEC_LAST))" -ge "$SEC_INTERVAL" ]; then
    SEC=$(collect_security 2>/dev/null || echo "")
    if [ -n "$SEC" ]; then
      if post_json "$SECURITY_URL" "$SEC"; then
        SEC_LAST=$NOW_TS
        echo "[$(now_iso)] security audit ok"
      else
        echo "[$(now_iso)] security audit failed" >&2
      fi
    else
      echo "[$(now_iso)] security audit: sin datos" >&2
    fi
  fi


  if [ "$ONCE" = "1" ]; then exit 0; fi
  sleep "$INTERVAL"
done
