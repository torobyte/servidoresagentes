#!/usr/bin/env bash
# Instalador TOROBYTE desatendido: WireGuard + WGDashboard
# By Brian Sanchez - TOROBYTE
# Adaptado y reforzado a partir de la idea de:
# https://github.com/devrimerduman/WireGuard-and-WGDashboard-Installer
# Usa WGDashboard v4.3.3, instala Python 3.12 cuando sea necesario e incluye
# interfaz wg0, NAT, UFW, systemd y diagnóstico final. Todos los comandos que
# podrían leer stdin se aíslan para permitir: curl URL | sudo bash.
#
# Uso:
#   sudo bash instalar_wireguard_wgdashboard.sh
#
# Variables opcionales:
#   DASHBOARD_ALLOWED_CIDR=any
#   WG_INTERFACE=wg0
#   WG_PORT=51820
#   VPN_SUBNET=10.66.66.0/24
#   SERVER_VPN_ADDRESS=10.66.66.1/24
#   DASHBOARD_PORT=10086
#   WGD_VERSION=v4.3.3

set -Eeuo pipefail
IFS=$'\n\t'
umask 077

WGD_VERSION="${WGD_VERSION:-v4.3.3}"
PYTHON_SOURCE_VERSION="${PYTHON_SOURCE_VERSION:-3.12.13}"
PYTHON_SOURCE_SHA256="${PYTHON_SOURCE_SHA256:-c08bc65a81971c1dd5783182826503369466c7e67374d1646519adf05207b684}"
PYTHON_BUILD_JOBS="${PYTHON_BUILD_JOBS:-2}"
INSTALL_DIR="${INSTALL_DIR:-/opt/WGDashboard}"
WG_INTERFACE="${WG_INTERFACE:-wg0}"
WG_PORT="${WG_PORT:-51820}"
VPN_SUBNET="${VPN_SUBNET:-10.66.66.0/24}"
SERVER_VPN_ADDRESS="${SERVER_VPN_ADDRESS:-10.66.66.1/24}"
DASHBOARD_PORT="${DASHBOARD_PORT:-10086}"
DASHBOARD_ALLOWED_CIDR="${DASHBOARD_ALLOWED_CIDR:-auto}"
ENABLE_UFW="${ENABLE_UFW:-true}"
LOG_FILE="${LOG_FILE:-/var/log/wireguard-wgdashboard-install.log}"
BACKUP_DIR="${BACKUP_DIR:-/var/backups/wireguard-wgdashboard}"
BRAND_AUTHOR="${BRAND_AUTHOR:-Brian Sanchez}"
BRAND_COMPANY="${BRAND_COMPANY:-TOROBYTE}"
WGD_WRAPPER="${WGD_WRAPPER:-/usr/local/sbin/torobyte-wgdashboard}"

GITHUB_REPO="https://github.com/WGDashboard/WGDashboard.git"

OK_COUNT=0
WARN_COUNT=0
FAIL_COUNT=0

mkdir -p "$(dirname "$LOG_FILE")"
touch "$LOG_FILE"
chmod 600 "$LOG_FILE"
exec > >(tee -a "$LOG_FILE") 2>&1

blue='\033[1;34m'
green='\033[1;32m'
yellow='\033[1;33m'
red='\033[1;31m'
reset='\033[0m'

info() { printf "${blue}[INFO]${reset} %s\n" "$*"; }
ok() { printf "${green}[OK]${reset} %s\n" "$*"; }
warn() { printf "${yellow}[AVISO]${reset} %s\n" "$*"; }
fatal() { printf "${red}[ERROR]${reset} %s\n" "$*" >&2; exit 1; }

# Oculta únicamente el banner repetitivo del ejecutable original en consola.
# No modifica el código fuente, la licencia ni los avisos legales de WGDashboard.
filter_wgd_output() {
    sed -E '/<WGDashboard>[[:space:]]+by[[:space:]]+Donald[[:space:]]+Zou/d; /github\.com\/donaldzou/d'
}

print_torobyte_brand() {
    echo
    printf "${blue}<WireGuard + WGDashboard>${reset} By %s - %s\n" "$BRAND_AUTHOR" "$BRAND_COMPANY"
    echo
}

on_error() {
    local code=$?
    local line="${BASH_LINENO[0]:-desconocida}"

    if [[ "${TEMP_SWAP_CREATED:-false}" == "true" ]]; then
        swapoff /swapfile-wgdashboard 2>/dev/null || true
        rm -f /swapfile-wgdashboard
    fi

    printf "\n${red}[ERROR] Instalación detenida en la línea %s, código %s.${reset}\n" "$line" "$code"
    printf "[ERROR] Registro completo: %s\n" "$LOG_FILE"
    exit "$code"
}
trap on_error ERR

is_true() {
    case "${1,,}" in
        1|true|yes|si|sí|on) return 0 ;;
        *) return 1 ;;
    esac
}

validate_port() {
    local value="$1"
    [[ "$value" =~ ^[0-9]+$ ]] || fatal "Puerto inválido: $value"
    (( value >= 1 && value <= 65535 )) || fatal "Puerto fuera de rango: $value"
}

validate_ipv4_interface() {
    python3 - "$1" <<'PY'
import ipaddress, sys
value = ipaddress.ip_interface(sys.argv[1])
raise SystemExit(0 if value.version == 4 else 1)
PY
}

validate_ipv4_network() {
    python3 - "$1" <<'PY'
import ipaddress, sys
value = ipaddress.ip_network(sys.argv[1], strict=False)
raise SystemExit(0 if value.version == 4 else 1)
PY
}

normalize_acl() {
    local value="$1"
    if [[ "$value" == "any" ]]; then
        printf 'any'
    elif [[ "$value" == */* ]]; then
        printf '%s' "$value"
    elif [[ "$value" == *:* ]]; then
        printf '%s/128' "$value"
    else
        printf '%s/32' "$value"
    fi
}

require_root() {
    [[ "${EUID}" -eq 0 ]] || fatal "Ejecuta el instalador con sudo o como root."
}

check_os() {
    [[ -r /etc/os-release ]] || fatal "No existe /etc/os-release."
    # shellcheck disable=SC1091
    . /etc/os-release
    [[ "${ID:-}" == "ubuntu" ]] || fatal "Sistema no compatible: ${ID:-desconocido}."

    case "${VERSION_ID:-}" in
        20.04|22.04|24.04)
            ok "Ubuntu ${VERSION_ID} detectado."
            ;;
        *)
            warn "Ubuntu ${VERSION_ID:-desconocido}; el instalador fue preparado para 20.04, 22.04 y 24.04."
            ;;
    esac

    OS_VERSION_ID="${VERSION_ID:-desconocido}"
}

check_parameters() {
    validate_port "$WG_PORT"
    validate_port "$DASHBOARD_PORT"
    validate_ipv4_network "$VPN_SUBNET" || fatal "VPN_SUBNET inválida: $VPN_SUBNET"
    validate_ipv4_interface "$SERVER_VPN_ADDRESS" || fatal "SERVER_VPN_ADDRESS inválida: $SERVER_VPN_ADDRESS"

    python3 - "$VPN_SUBNET" "$SERVER_VPN_ADDRESS" <<'PY' || fatal "La IP del servidor no pertenece a VPN_SUBNET."
import ipaddress, sys
network = ipaddress.ip_network(sys.argv[1], strict=False)
server = ipaddress.ip_interface(sys.argv[2])
raise SystemExit(0 if server.ip in network else 1)
PY

    [[ "$WG_INTERFACE" =~ ^[a-zA-Z0-9_=+.-]{1,15}$ ]] \
        || fatal "Nombre de interfaz WireGuard inválido: $WG_INTERFACE"
}

check_connectivity() {
    info "Comprobando acceso a Ubuntu y GitHub..."
    curl -fsSI --retry 3 --connect-timeout 15 https://github.com/ >/dev/null \
        || fatal "No hay acceso HTTPS a GitHub."
    curl -fsSI --retry 3 --connect-timeout 15 https://archive.ubuntu.com/ >/dev/null \
        || warn "No respondió archive.ubuntu.com; apt usará los repositorios configurados en el servidor."
    ok "Conectividad comprobada."
}

install_dependencies() {
    info "Actualizando paquetes e instalando WireGuard y todas las dependencias..."
    export DEBIAN_FRONTEND=noninteractive
    export NEEDRESTART_MODE=a
    export APT_LISTCHANGES_FRONTEND=none

    apt-get update </dev/null
    apt-get install -y --no-install-recommends \
        wireguard-tools \
        git \
        net-tools \
        iproute2 \
        iptables \
        nftables \
        iputils-ping \
        python3 \
        python3-venv \
        python3-pip \
        python3-dev \
        build-essential \
        pkg-config \
        curl \
        wget \
        ca-certificates \
        xz-utils \
        tar \
        sudo \
        ufw \
        qrencode \
        libssl-dev \
        zlib1g-dev \
        libncurses-dev \
        libreadline-dev \
        libsqlite3-dev \
        libgdbm-dev \
        libbz2-dev \
        libexpat1-dev \
        liblzma-dev \
        tk-dev \
        libffi-dev \
        uuid-dev < /dev/null

    ok "APT terminó sin consumir el instalador; continuando con Python y WGDashboard."

    command -v wg >/dev/null 2>&1 || fatal "No se instaló el comando wg."
    command -v wg-quick >/dev/null 2>&1 || fatal "No se instaló wg-quick."
    command -v python3 >/dev/null 2>&1 || fatal "No se instaló Python del sistema."

    ensure_python312

    ok "WireGuard instalado: $(wg --version 2>/dev/null || echo disponible)."
    ok "Python para WGDashboard: $(${PYTHON_BIN} --version 2>&1)."
}

python_is_compatible() {
    local candidate="$1"
    [[ -x "$candidate" || -n "$(command -v "$candidate" 2>/dev/null || true)" ]] || return 1
    "$candidate" - <<'PY' >/dev/null 2>&1
import sys
raise SystemExit(0 if sys.version_info >= (3, 12) else 1)
PY
}

verify_python_modules() {
    "$1" - <<'PY' >/dev/null 2>&1
import bz2
import ctypes
import ensurepip
import lzma
import sqlite3
import ssl
import venv
PY
}

create_temporary_swap_if_needed() {
    TEMP_SWAP_CREATED="false"
    local available_kb swap_total_kb
    available_kb="$(awk '/MemAvailable:/ {print $2}' /proc/meminfo 2>/dev/null || echo 0)"
    swap_total_kb="$(awk '/SwapTotal:/ {print $2}' /proc/meminfo 2>/dev/null || echo 0)"

    if (( available_kb < 700000 && swap_total_kb < 500000 )); then
        warn "Memoria disponible baja; creando swap temporal de 2 GB para compilar Python."
        if [[ ! -e /swapfile-wgdashboard ]]; then
            fallocate -l 2G /swapfile-wgdashboard 2>/dev/null \
                || dd if=/dev/zero of=/swapfile-wgdashboard bs=1M count=2048 status=none
            chmod 600 /swapfile-wgdashboard
            mkswap /swapfile-wgdashboard >/dev/null
            swapon /swapfile-wgdashboard
            TEMP_SWAP_CREATED="true"
        fi
    fi
}

remove_temporary_swap() {
    if [[ "${TEMP_SWAP_CREATED:-false}" == "true" ]]; then
        swapoff /swapfile-wgdashboard 2>/dev/null || true
        rm -f /swapfile-wgdashboard
        ok "Swap temporal eliminado."
    fi
}

install_python312_from_source() {
    local workdir="/usr/local/src/python-${PYTHON_SOURCE_VERSION}-wgdashboard"
    local archive="${workdir}/Python-${PYTHON_SOURCE_VERSION}.tar.xz"
    local source_dir="${workdir}/Python-${PYTHON_SOURCE_VERSION}"
    local url="https://www.python.org/ftp/python/${PYTHON_SOURCE_VERSION}/Python-${PYTHON_SOURCE_VERSION}.tar.xz"

    info "Python 3.12 no está disponible en APT. Se instalará Python ${PYTHON_SOURCE_VERSION} desde python.org."
    create_temporary_swap_if_needed
    rm -rf "$workdir"
    mkdir -p "$workdir"

    curl -fL --retry 3 --connect-timeout 20 "$url" -o "$archive"
    echo "${PYTHON_SOURCE_SHA256}  ${archive}" | sha256sum -c - \
        || fatal "La suma SHA-256 del código fuente de Python no coincide."

    tar -xJf "$archive" -C "$workdir"
    cd "$source_dir"

    ./configure \
        --prefix=/usr/local \
        --with-ensurepip=install

    make -j"${PYTHON_BUILD_JOBS}"
    make altinstall

    remove_temporary_swap
    rm -rf "$workdir"

    [[ -x /usr/local/bin/python3.12 ]] \
        || fatal "La compilación terminó, pero /usr/local/bin/python3.12 no existe."
}

ensure_python312() {
    PYTHON_BIN=""

    [[ "$PYTHON_BUILD_JOBS" =~ ^[1-9][0-9]*$ ]] \
        || fatal "PYTHON_BUILD_JOBS debe ser un número entero mayor que cero."

    for candidate in python3.14 python3.13 python3.12 /usr/local/bin/python3.12; do
        if python_is_compatible "$candidate"; then
            PYTHON_BIN="$(command -v "$candidate" 2>/dev/null || printf '%s' "$candidate")"
            break
        fi
    done

    if [[ -z "$PYTHON_BIN" ]]; then
        info "Buscando Python 3.12 en los repositorios de Ubuntu..."
        if apt-cache show python3.12 >/dev/null 2>&1; then
            if ! apt-get install -y --no-install-recommends \
                python3.12 python3.12-venv python3.12-dev < /dev/null; then
                warn "APT no pudo instalar el conjunto completo de Python 3.12; se usará compilación desde fuente."
            fi
        fi

        if python_is_compatible python3.12; then
            PYTHON_BIN="$(command -v python3.12)"
        else
            install_python312_from_source
            PYTHON_BIN="/usr/local/bin/python3.12"
        fi
    fi

    python_is_compatible "$PYTHON_BIN" \
        || fatal "No se obtuvo una versión de Python compatible con WGDashboard."
    verify_python_modules "$PYTHON_BIN" \
        || fatal "Python ${PYTHON_BIN} quedó sin módulos esenciales (ssl/sqlite3/bz2/lzma/venv)."

    export PYTHON_BIN
    ok "Python compatible disponible: $(${PYTHON_BIN} --version 2>&1) en ${PYTHON_BIN}."
}

detect_network() {
    EXTERNAL_INTERFACE="$(ip -4 route show default | awk 'NR==1 {print $5}')"
    [[ -n "$EXTERNAL_INTERFACE" ]] || fatal "No se pudo detectar la interfaz de Internet."
    [[ "$EXTERNAL_INTERFACE" =~ ^[a-zA-Z0-9_.:-]+$ ]] \
        || fatal "Interfaz externa inválida: $EXTERNAL_INTERFACE"
    ok "Interfaz de Internet detectada: $EXTERNAL_INTERFACE."
}

configure_forwarding() {
    info "Habilitando reenvío IPv4..."
    cat > /etc/sysctl.d/99-wireguard-forwarding.conf <<'EOF'
net.ipv4.ip_forward=1
EOF
    chmod 644 /etc/sysctl.d/99-wireguard-forwarding.conf
    sysctl --system >/dev/null
    [[ "$(sysctl -n net.ipv4.ip_forward)" == "1" ]] \
        || fatal "No se pudo habilitar net.ipv4.ip_forward."
    ok "Reenvío IPv4 habilitado."
}

create_wireguard_interface() {
    local conf="/etc/wireguard/${WG_INTERFACE}.conf"
    install -d -m 700 /etc/wireguard

    if [[ -f "$conf" ]]; then
        warn "$conf ya existe; se conservará sin reemplazar."
        chmod 600 "$conf"
    else
        info "Creando la interfaz ${WG_INTERFACE}..."
        local private_key
        private_key="$(wg genkey)"

        cat > "$conf" <<EOF
[Interface]
Address = ${SERVER_VPN_ADDRESS}
ListenPort = ${WG_PORT}
PrivateKey = ${private_key}
PostUp = iptables -C FORWARD -i %i -j ACCEPT 2>/dev/null || iptables -A FORWARD -i %i -j ACCEPT; iptables -C FORWARD -o %i -j ACCEPT 2>/dev/null || iptables -A FORWARD -o %i -j ACCEPT; iptables -t nat -C POSTROUTING -s ${VPN_SUBNET} -o ${EXTERNAL_INTERFACE} -j MASQUERADE 2>/dev/null || iptables -t nat -A POSTROUTING -s ${VPN_SUBNET} -o ${EXTERNAL_INTERFACE} -j MASQUERADE
PostDown = iptables -D FORWARD -i %i -j ACCEPT 2>/dev/null || true; iptables -D FORWARD -o %i -j ACCEPT 2>/dev/null || true; iptables -t nat -D POSTROUTING -s ${VPN_SUBNET} -o ${EXTERNAL_INTERFACE} -j MASQUERADE 2>/dev/null || true
EOF
        chmod 600 "$conf"
        ok "Configuración creada: $conf."
    fi

    systemctl enable "wg-quick@${WG_INTERFACE}.service" >/dev/null
    if ! systemctl restart "wg-quick@${WG_INTERFACE}.service"; then
        journalctl -u "wg-quick@${WG_INTERFACE}.service" -n 80 --no-pager || true
        fatal "No se pudo iniciar WireGuard ${WG_INTERFACE}."
    fi

    wg show "$WG_INTERFACE" >/dev/null 2>&1 \
        || fatal "La interfaz ${WG_INTERFACE} no responde."
    ok "WireGuard ${WG_INTERFACE} activo."
}

backup_existing_installation() {
    local stamp backup_file
    stamp="$(date +%Y%m%d-%H%M%S)"
    mkdir -p "$BACKUP_DIR"
    chmod 700 "$BACKUP_DIR"

    if [[ -d /etc/wireguard ]] && find /etc/wireguard -mindepth 1 -print -quit | grep -q .; then
        backup_file="${BACKUP_DIR}/wireguard-${stamp}.tar.gz"
        tar -czf "$backup_file" -C /etc wireguard
        chmod 600 "$backup_file"
        ok "Respaldo WireGuard creado: $backup_file."
    fi

    if [[ -d "${INSTALL_DIR}/src/db" || -f "${INSTALL_DIR}/src/wg-dashboard.ini" ]]; then
        backup_file="${BACKUP_DIR}/wgdashboard-${stamp}.tar.gz"
        local -a items=()
        [[ -d "${INSTALL_DIR}/src/db" ]] && items+=("db")
        [[ -f "${INSTALL_DIR}/src/wg-dashboard.ini" ]] && items+=("wg-dashboard.ini")
        [[ -f "${INSTALL_DIR}/src/ssl-tls.ini" ]] && items+=("ssl-tls.ini")
        tar -czf "$backup_file" -C "${INSTALL_DIR}/src" "${items[@]}"
        chmod 600 "$backup_file"
        ok "Respaldo WGDashboard creado: $backup_file."
    fi
}

stop_legacy_dashboard_services() {
    local unit
    for unit in wgdashboard.service wg-dashboard.service; do
        if systemctl list-unit-files --type=service 2>/dev/null | awk '{print $1}' | grep -Fxq "$unit"; then
            systemctl stop "$unit" 2>/dev/null || true
        fi
    done

    # Evita conflictos con instalaciones antiguas que ejecutaban dashboard.py directamente.
    pkill -f '/opt/WGDashboard/src/dashboard.py' 2>/dev/null || true
    rm -f "${INSTALL_DIR}/src/gunicorn.pid" 2>/dev/null || true
}

install_wgdashboard() {
    info "Instalando WGDashboard ${WGD_VERSION} mediante instalador TOROBYTE..."

    if [[ -d "${INSTALL_DIR}/.git" ]]; then
        info "Repositorio existente detectado; actualizando."
        GIT_TERMINAL_PROMPT=0 git -C "$INSTALL_DIR" fetch --tags --force origin < /dev/null
        GIT_TERMINAL_PROMPT=0 git -C "$INSTALL_DIR" checkout -f "$WGD_VERSION" < /dev/null
    elif [[ -e "$INSTALL_DIR" ]]; then
        local backup="${INSTALL_DIR}.anterior.$(date +%Y%m%d-%H%M%S)"
        warn "$INSTALL_DIR existe pero no es un repositorio válido; se moverá a $backup."
        mv "$INSTALL_DIR" "$backup"
        GIT_TERMINAL_PROMPT=0 git clone --depth 1 --branch "$WGD_VERSION" "$GITHUB_REPO" "$INSTALL_DIR" < /dev/null
    else
        GIT_TERMINAL_PROMPT=0 git clone --depth 1 --branch "$WGD_VERSION" "$GITHUB_REPO" "$INSTALL_DIR" < /dev/null
    fi

    cd "${INSTALL_DIR}/src"
    chmod 750 ./wgd.sh
    install -d -m 755 log download db

    if [[ -x ./venv/bin/python3 ]]; then
        if ! ./venv/bin/python3 - <<'PY' >/dev/null 2>&1
import sys
raise SystemExit(0 if sys.version_info >= (3, 12) else 1)
PY
        then
            warn "Se encontró un entorno virtual antiguo; será recreado con ${PYTHON_BIN}."
            rm -rf ./venv
        fi
    fi

    info "Ejecutando el instalador oficial de WGDashboard con todas sus dependencias..."
    print_torobyte_brand
    printf '\n' | PATH="$(dirname "$PYTHON_BIN"):${PATH}" ./wgd.sh install 2>&1 | filter_wgd_output

    [[ -x "${INSTALL_DIR}/src/venv/bin/python3" ]] \
        || fatal "WGDashboard no creó el entorno virtual."
    [[ -x "${INSTALL_DIR}/src/venv/bin/gunicorn" ]] \
        || {
            tail -n 120 "${INSTALL_DIR}/src/log/install.txt" 2>/dev/null || true
            fatal "WGDashboard no instaló Gunicorn."
        }

    # El instalador oficial puede ampliar permisos; se vuelven a restringir.
    chmod 700 /etc/wireguard
    find /etc/wireguard -type d -exec chmod 700 {} +
    find /etc/wireguard -type f -exec chmod 600 {} +

    ok "WGDashboard instalado en ${INSTALL_DIR}."
}

generate_dashboard_config() {
    local ini="${INSTALL_DIR}/src/wg-dashboard.ini"

    info "Generando la configuración inicial de WGDashboard..."
    cd "${INSTALL_DIR}/src"

    rm -f gunicorn.pid
    ./wgd.sh start 2>&1 | filter_wgd_output

    local attempt
    for attempt in $(seq 1 45); do
        [[ -f "$ini" ]] && break
        sleep 1
    done

    if [[ -f gunicorn.pid ]]; then
        ./wgd.sh stop 2>&1 | filter_wgd_output || true
    else
        pkill -f "${INSTALL_DIR}/src/venv/bin/gunicorn" 2>/dev/null || true
    fi

    [[ -f "$ini" ]] || {
        tail -n 120 "${INSTALL_DIR}/src/log/install.txt" 2>/dev/null || true
        fatal "No se generó wg-dashboard.ini."
    }

    python3 - "$ini" "$DASHBOARD_PORT" "$VPN_SUBNET" <<'PY'
import configparser
import os
import sys
import tempfile

path, port, subnet = sys.argv[1:]
cfg = configparser.ConfigParser(interpolation=None)
cfg.optionxform = str
cfg.read(path, encoding="utf-8")

if not cfg.has_section("Server"):
    cfg.add_section("Server")
cfg.set("Server", "app_ip", "0.0.0.0")
cfg.set("Server", "app_port", port)
cfg.set("Server", "auth_req", "true")
cfg.set("Server", "wg_conf_path", "/etc/wireguard")

if not cfg.has_section("Peers"):
    cfg.add_section("Peers")
cfg.set("Peers", "peer_endpoint_allowed_ip", subnet)
cfg.set("Peers", "peer_global_dns", "8.8.8.8")
cfg.set("Peers", "peer_keep_alive", "21")
cfg.set("Peers", "peer_mtu", "1420")

fd, tmp = tempfile.mkstemp(prefix="wg-dashboard-", suffix=".ini", dir=os.path.dirname(path))
try:
    with os.fdopen(fd, "w", encoding="utf-8") as handle:
        cfg.write(handle)
        handle.flush()
        os.fsync(handle.fileno())
    os.chmod(tmp, 0o600)
    os.replace(tmp, path)
finally:
    if os.path.exists(tmp):
        os.unlink(tmp)
PY

    chmod 600 "$ini"
    ok "WGDashboard configurado en el puerto ${DASHBOARD_PORT}."
}

create_dashboard_service() {
    info "Creando el servicio systemd de WGDashboard administrado por TOROBYTE..."

    cat > "$WGD_WRAPPER" <<EOF_WRAPPER
#!/usr/bin/env bash
set -o pipefail
cd "${INSTALL_DIR}/src"
./wgd.sh "\$@" 2>&1 | sed -E '/<WGDashboard>[[:space:]]+by[[:space:]]+Donald[[:space:]]+Zou/d; /github\\.com\\/donaldzou/d'
EOF_WRAPPER
    chmod 750 "$WGD_WRAPPER"
    chown root:root "$WGD_WRAPPER"

    cat > /etc/systemd/system/wg-dashboard.service <<EOF
[Unit]
Description=WGDashboard administrado por TOROBYTE
Documentation=https://docs.wgdashboard.dev/
After=network-online.target wg-quick@${WG_INTERFACE}.service
Wants=network-online.target
ConditionPathIsDirectory=/etc/wireguard

[Service]
Type=forking
Environment="PATH=$(dirname "$PYTHON_BIN"):/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
User=root
Group=root
WorkingDirectory=${INSTALL_DIR}/src
PIDFile=${INSTALL_DIR}/src/gunicorn.pid
ExecStart=${WGD_WRAPPER} start
ExecStop=${WGD_WRAPPER} stop
ExecReload=${WGD_WRAPPER} restart
TimeoutStartSec=180
TimeoutStopSec=90
Restart=on-failure
RestartSec=5
UMask=0077
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF

    chmod 644 /etc/systemd/system/wg-dashboard.service
    systemctl daemon-reload
    systemctl enable wg-dashboard.service >/dev/null

    rm -f "${INSTALL_DIR}/src/gunicorn.pid"
    if ! systemctl restart wg-dashboard.service; then
        systemctl status wg-dashboard.service --no-pager || true
        journalctl -u wg-dashboard.service -n 120 --no-pager || true
        fatal "WGDashboard no pudo iniciar."
    fi

    sleep 5
    systemctl is-active --quiet wg-dashboard.service \
        || {
            systemctl status wg-dashboard.service --no-pager || true
            journalctl -u wg-dashboard.service -n 120 --no-pager || true
            fatal "wg-dashboard.service no está activo."
        }

    ok "Servicio wg-dashboard activo."
}

detect_ssh() {
    SSH_PORT=""
    SSH_SOURCE_IP=""

    if [[ -n "${SSH_CONNECTION:-}" ]]; then
        read -r SSH_SOURCE_IP _ _ SSH_PORT <<< "$SSH_CONNECTION"
    elif [[ -n "${SSH_CLIENT:-}" ]]; then
        read -r SSH_SOURCE_IP _ SSH_PORT <<< "$SSH_CLIENT"
    fi

    if [[ -z "$SSH_SOURCE_IP" ]]; then
        SSH_SOURCE_IP="$(who -m 2>/dev/null | awk '{print $NF}' | tr -d '()' || true)"
    fi

    if [[ -z "$SSH_PORT" ]]; then
        SSH_PORT="$(sshd -T 2>/dev/null | awk '$1=="port" {print $2; exit}' || true)"
    fi

    SSH_PORT="${SSH_PORT:-22}"
    validate_port "$SSH_PORT"
}

configure_firewall() {
    is_true "$ENABLE_UFW" || {
        warn "UFW fue omitido mediante ENABLE_UFW=false."
        return 0
    }

    detect_ssh

    if [[ "$DASHBOARD_ALLOWED_CIDR" == "auto" ]]; then
        if [[ -n "$SSH_SOURCE_IP" ]]; then
            DASHBOARD_ALLOWED_CIDR="$(normalize_acl "$SSH_SOURCE_IP")"
        else
            DASHBOARD_ALLOWED_CIDR="any"
            warn "No se detectó la IP SSH; el panel se abrirá temporalmente a cualquier IP."
        fi
    else
        DASHBOARD_ALLOWED_CIDR="$(normalize_acl "$DASHBOARD_ALLOWED_CIDR")"
    fi

    info "Configurando UFW..."
    ufw allow "${SSH_PORT}/tcp" comment 'SSH administracion' >/dev/null
    ufw allow "${WG_PORT}/udp" comment 'WireGuard VPN' >/dev/null

    if [[ "$DASHBOARD_ALLOWED_CIDR" == "any" ]]; then
        ufw allow "${DASHBOARD_PORT}/tcp" comment 'WGDashboard' >/dev/null
        warn "WGDashboard está expuesto en Internet. Cambia admin/admin inmediatamente."
    else
        ufw allow from "$DASHBOARD_ALLOWED_CIDR" to any port "$DASHBOARD_PORT" proto tcp \
            comment 'WGDashboard restringido' >/dev/null
    fi

    ufw default deny incoming >/dev/null
    ufw default allow outgoing >/dev/null
    ufw --force enable >/dev/null
    ufw reload >/dev/null

    systemctl restart "wg-quick@${WG_INTERFACE}.service"
    ok "UFW activo."
}

diag_ok() {
    OK_COUNT=$((OK_COUNT + 1))
    printf "${green}[CORRECTO]${reset} %s\n" "$*"
}

diag_warn() {
    WARN_COUNT=$((WARN_COUNT + 1))
    printf "${yellow}[ADVERTENCIA]${reset} %s\n" "$*"
}

diag_fail() {
    FAIL_COUNT=$((FAIL_COUNT + 1))
    printf "${red}[FALLO]${reset} %s\n" "$*"
}

run_diagnostics() {
    echo
    echo "============================================================================"
    echo " DIAGNÓSTICO FINAL"
    echo "============================================================================"

    dpkg-query -W -f='${Status}' wireguard-tools 2>/dev/null | grep -q "install ok installed" \
        && diag_ok "Paquete wireguard-tools instalado." \
        || diag_fail "wireguard-tools no está instalado."

    command -v wg >/dev/null 2>&1 \
        && diag_ok "Comando wg disponible." \
        || diag_fail "Comando wg no disponible."

    if [[ -n "${PYTHON_BIN:-}" ]] && python_is_compatible "$PYTHON_BIN"; then
        diag_ok "Python compatible para WGDashboard: $(${PYTHON_BIN} --version 2>&1)."
    else
        diag_fail "No se detecta Python 3.12 o superior para WGDashboard."
    fi

    if [[ -x "${INSTALL_DIR}/src/venv/bin/python3" ]] && \
       "${INSTALL_DIR}/src/venv/bin/python3" - <<'PY' >/dev/null 2>&1
import sys
raise SystemExit(0 if sys.version_info >= (3, 12) else 1)
PY
    then
        diag_ok "Entorno virtual de WGDashboard usa $(${INSTALL_DIR}/src/venv/bin/python3 --version 2>&1)."
    else
        diag_fail "El entorno virtual de WGDashboard no usa Python 3.12 o superior."
    fi

    systemctl is-enabled --quiet "wg-quick@${WG_INTERFACE}.service" \
        && diag_ok "WireGuard habilitado al iniciar." \
        || diag_fail "WireGuard no está habilitado al iniciar."

    systemctl is-active --quiet "wg-quick@${WG_INTERFACE}.service" \
        && diag_ok "WireGuard está activo." \
        || diag_fail "WireGuard no está activo."

    wg show "$WG_INTERFACE" >/dev/null 2>&1 \
        && diag_ok "La interfaz ${WG_INTERFACE} responde." \
        || diag_fail "La interfaz ${WG_INTERFACE} no responde."

    [[ -d "${INSTALL_DIR}/src" ]] \
        && diag_ok "Directorio WGDashboard disponible." \
        || diag_fail "No existe ${INSTALL_DIR}/src."

    [[ -x "${INSTALL_DIR}/src/venv/bin/gunicorn" ]] \
        && diag_ok "Gunicorn de WGDashboard instalado." \
        || diag_fail "Gunicorn no está instalado."

    systemctl is-enabled --quiet wg-dashboard.service \
        && diag_ok "WGDashboard habilitado al iniciar." \
        || diag_fail "WGDashboard no está habilitado al iniciar."

    systemctl is-active --quiet wg-dashboard.service \
        && diag_ok "WGDashboard está activo." \
        || diag_fail "WGDashboard no está activo."

    ss -H -lnu | awk '{print $4}' | grep -Eq "(^|:)${WG_PORT}$" \
        && diag_ok "WireGuard escucha en ${WG_PORT}/UDP." \
        || diag_fail "No se detecta ${WG_PORT}/UDP."

    ss -H -lnt | awk '{print $4}' | grep -Eq "(^|:)${DASHBOARD_PORT}$" \
        && diag_ok "WGDashboard escucha en ${DASHBOARD_PORT}/TCP." \
        || diag_fail "No se detecta ${DASHBOARD_PORT}/TCP."

    local http_code
    http_code="$(curl -sS -o /dev/null --max-time 10 -w '%{http_code}' \
        "http://127.0.0.1:${DASHBOARD_PORT}" 2>/dev/null || true)"

    case "$http_code" in
        200|301|302|303|307|308|401|403)
            diag_ok "WGDashboard responde localmente con HTTP ${http_code}."
            ;;
        *)
            diag_fail "WGDashboard no responde correctamente; HTTP ${http_code:-000}."
            ;;
    esac

    [[ "$(sysctl -n net.ipv4.ip_forward 2>/dev/null || true)" == "1" ]] \
        && diag_ok "Reenvío IPv4 habilitado." \
        || diag_fail "Reenvío IPv4 deshabilitado."

    iptables -t nat -C POSTROUTING -s "$VPN_SUBNET" -o "$EXTERNAL_INTERFACE" \
        -j MASQUERADE >/dev/null 2>&1 \
        && diag_ok "NAT MASQUERADE activo." \
        || diag_fail "Falta NAT MASQUERADE."

    if is_true "$ENABLE_UFW"; then
        LC_ALL=C ufw status | grep -q '^Status: active' \
            && diag_ok "UFW está activo." \
            || diag_fail "UFW no está activo."
    else
        diag_warn "UFW no fue configurado."
    fi

    echo
    printf "RESULTADO: %d correctos | %d advertencias | %d fallos\n" \
        "$OK_COUNT" "$WARN_COUNT" "$FAIL_COUNT"
}

print_summary() {
    local server_ip public_ip public_key
    server_ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
    public_ip="$(curl -4fsS --max-time 8 https://api.ipify.org 2>/dev/null || true)"
    public_key="$(wg show "$WG_INTERFACE" public-key 2>/dev/null || true)"

    cat <<EOF

============================================================================
 INSTALACIÓN FINALIZADA - TOROBYTE
 By Brian Sanchez - TOROBYTE
============================================================================
 Panel:              http://${server_ip:-IP_DEL_SERVIDOR}:${DASHBOARD_PORT}
 Usuario inicial:    admin
 Contraseña inicial: admin
 Acceso UFW:         ${DASHBOARD_ALLOWED_CIDR}

 Python WGDashboard: $(${PYTHON_BIN} --version 2>&1)
 Interfaz VPN:       ${WG_INTERFACE}
 IP VPN servidor:   ${SERVER_VPN_ADDRESS}
 Red VPN:            ${VPN_SUBNET}
 Puerto WireGuard:   ${WG_PORT}/UDP
 IP pública:         ${public_ip:-no detectada}
 Clave pública:      ${public_key:-no disponible}

 Registro:           ${LOG_FILE}
 Respaldos:          ${BACKUP_DIR}
============================================================================

IMPORTANTE:
  - Cambia inmediatamente la contraseña admin/admin.
  - Para split tunnel usa AllowedIPs = ${VPN_SUBNET}
  - No uses 0.0.0.0/0 salvo que quieras enviar todo Internet por la VPN.

EOF
}

main() {
    echo "============================================================================"
    echo " INSTALADOR TOROBYTE - WIREGUARD + WGDASHBOARD"
    echo " By ${BRAND_AUTHOR} - ${BRAND_COMPANY}"
    echo " Ubuntu 20.04 / 22.04 / 24.04"
    echo " Inicio: $(date '+%Y-%m-%d %H:%M:%S')"
    echo "============================================================================"

    require_root
    check_os
    install_dependencies
    check_parameters
    check_connectivity
    backup_existing_installation
    stop_legacy_dashboard_services
    detect_network
    configure_forwarding
    create_wireguard_interface
    install_wgdashboard
    generate_dashboard_config
    create_dashboard_service
    configure_firewall
    run_diagnostics
    print_summary

    if (( FAIL_COUNT > 0 )); then
        fatal "El diagnóstico detectó ${FAIL_COUNT} fallo(s). Revisa ${LOG_FILE}."
    fi

    ok "WireGuard y WGDashboard quedaron instalados y operativos por ${BRAND_AUTHOR} - ${BRAND_COMPANY}."
}

main "$@"
