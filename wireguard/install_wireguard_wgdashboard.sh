#!/usr/bin/env bash
# Instalador automático de WireGuard + WGDashboard para Ubuntu Server 24.04 LTS
# Ejecutar como root: sudo bash instalar_wireguard_wgdashboard.sh

set -Eeuo pipefail
IFS=$'\n\t'
umask 077

# ==============================================================================
# VARIABLES EDITABLES
# También pueden definirse como variables de entorno antes de ejecutar el script.
# Ejemplo:
#   DASHBOARD_ALLOWED_CIDR="203.0.113.10/32" VPN_SUBNET="10.80.0.0/24" \
#   sudo -E bash instalar_wireguard_wgdashboard.sh
# ==============================================================================
WGD_VERSION="${WGD_VERSION:-latest}"                    # latest o una etiqueta como v4.3.3
INSTALL_DIR="${INSTALL_DIR:-/opt/WGDashboard}"
DASHBOARD_PORT="${DASHBOARD_PORT:-10086}"
DASHBOARD_ALLOWED_CIDR="${DASHBOARD_ALLOWED_CIDR:-auto}" # auto, any, CIDR o IP
WG_INTERFACE="${WG_INTERFACE:-wg0}"
WG_PORT="${WG_PORT:-51820}"
VPN_SUBNET="${VPN_SUBNET:-10.66.66.0/24}"
SERVER_VPN_ADDRESS="${SERVER_VPN_ADDRESS:-10.66.66.1/24}"
CREATE_INITIAL_INTERFACE="${CREATE_INITIAL_INTERFACE:-true}"
ENABLE_NAT="${ENABLE_NAT:-true}"
ENABLE_UFW="${ENABLE_UFW:-true}"
ENABLE_IPV6_FORWARDING="${ENABLE_IPV6_FORWARDING:-false}"
LOG_FILE="${LOG_FILE:-/var/log/wireguard-wgdashboard-install.log}"

readonly GITHUB_REPO="https://github.com/WGDashboard/WGDashboard.git"
readonly GITHUB_API="https://api.github.com/repos/WGDashboard/WGDashboard/releases/latest"

mkdir -p "$(dirname "$LOG_FILE")"
touch "$LOG_FILE"
chmod 600 "$LOG_FILE"
exec > >(tee -a "$LOG_FILE") 2>&1

on_error() {
    local exit_code=$?
    local line=${BASH_LINENO[0]:-desconocida}
    echo
    echo "[ERROR] La instalación se detuvo en la línea ${line} (código ${exit_code})."
    echo "[ERROR] Revisa el registro: ${LOG_FILE}"
    exit "$exit_code"
}
trap on_error ERR

info()  { printf '\033[1;34m[INFO]\033[0m %s\n' "$*"; }
ok()    { printf '\033[1;32m[OK]\033[0m %s\n' "$*"; }
warn()  { printf '\033[1;33m[AVISO]\033[0m %s\n' "$*"; }
fatal() { printf '\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2; exit 1; }

is_true() {
    case "${1,,}" in
        true|1|yes|si|sí|on) return 0 ;;
        *) return 1 ;;
    esac
}

validate_port() {
    local name="$1" value="$2"
    [[ "$value" =~ ^[0-9]+$ ]] || fatal "$name debe ser numérico."
    (( value >= 1 && value <= 65535 )) || fatal "$name debe estar entre 1 y 65535."
}

validate_ipv4_cidr() {
    local value="$1"
    python3 - "$value" <<'PY'
import ipaddress
import sys
try:
    network = ipaddress.ip_network(sys.argv[1], strict=False)
    if network.version != 4:
        raise ValueError("Se requiere IPv4")
except ValueError:
    raise SystemExit(1)
PY
}

validate_ip_or_cidr() {
    local value="$1"
    python3 - "$value" <<'PY'
import ipaddress
import sys
try:
    if "/" in sys.argv[1]:
        ipaddress.ip_network(sys.argv[1], strict=False)
    else:
        ipaddress.ip_address(sys.argv[1])
except ValueError:
    raise SystemExit(1)
PY
}

normalize_ip_to_cidr() {
    local value="$1"
    if [[ "$value" == */* ]]; then
        printf '%s' "$value"
    elif [[ "$value" == *:* ]]; then
        printf '%s/128' "$value"
    else
        printf '%s/32' "$value"
    fi
}

require_root() {
    [[ "$EUID" -eq 0 ]] || fatal "Debes ejecutar este script como root: sudo bash $0"
}

check_ubuntu() {
    [[ -r /etc/os-release ]] || fatal "No se encontró /etc/os-release."
    # shellcheck disable=SC1091
    . /etc/os-release
    [[ "${ID:-}" == "ubuntu" ]] || fatal "Este instalador está diseñado para Ubuntu. Sistema detectado: ${ID:-desconocido}."
    if [[ "${VERSION_ID:-}" != "24.04" ]]; then
        warn "Fue diseñado y probado para Ubuntu 24.04. Detectado: ${VERSION_ID:-desconocido}."
    else
        ok "Ubuntu ${VERSION_ID} detectado."
    fi
}

check_network() {
    info "Comprobando conexión con los repositorios..."
    curl -fsSI --connect-timeout 10 https://github.com/ >/dev/null \
        || fatal "No hay acceso a GitHub. Revisa DNS, proxy o salida HTTPS."
    ok "Conectividad disponible."
}

install_packages() {
    info "Actualizando índices e instalando dependencias..."
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y
    apt-get install -y --no-install-recommends \
        wireguard wireguard-tools git net-tools iptables nftables \
        python3 python3-venv python3-pip python3-dev \
        build-essential pkg-config curl ca-certificates ufw qrencode sudo

    command -v wg >/dev/null || fatal "WireGuard no quedó instalado."
    command -v python3 >/dev/null || fatal "Python 3 no quedó instalado."

    local py_minor
    py_minor="$(python3 -c 'import sys; print(sys.version_info.minor)')"
    (( py_minor >= 12 )) || fatal "WGDashboard actual requiere Python 3.12 o superior. Detectado: $(python3 --version)."
    ok "Dependencias instaladas. Python: $(python3 --version)."
}

resolve_wgd_version() {
    if [[ "$WGD_VERSION" != "latest" ]]; then
        RESOLVED_WGD_VERSION="$WGD_VERSION"
    else
        RESOLVED_WGD_VERSION="$(curl -fsSL --connect-timeout 15 "$GITHUB_API" \
            | python3 -c 'import json,sys; print(json.load(sys.stdin)["tag_name"])' 2>/dev/null || true)"
        if [[ -z "$RESOLVED_WGD_VERSION" ]]; then
            RESOLVED_WGD_VERSION="v4.3.3"
            warn "No se pudo consultar la versión más reciente. Se usará la versión segura de respaldo ${RESOLVED_WGD_VERSION}."
        fi
    fi

    [[ "$RESOLVED_WGD_VERSION" =~ ^v[0-9]+\.[0-9]+\.[0-9]+([.-][0-9]+)*$ ]] \
        || fatal "Versión WGDashboard inválida: $RESOLVED_WGD_VERSION"
    info "Versión seleccionada de WGDashboard: ${RESOLVED_WGD_VERSION}"
}

backup_existing_wgd() {
    [[ -d "$INSTALL_DIR" ]] || return 0
    local backup_dir="/var/backups/wgdashboard"
    local backup_file="${backup_dir}/wgdashboard-$(date +%Y%m%d-%H%M%S).tar.gz"
    mkdir -p "$backup_dir"

    if [[ -d "$INSTALL_DIR/src/db" || -f "$INSTALL_DIR/src/wg-dashboard.ini" ]]; then
        local -a backup_items=()
        [[ -d "$INSTALL_DIR/src/db" ]] && backup_items+=("db")
        [[ -f "$INSTALL_DIR/src/wg-dashboard.ini" ]] && backup_items+=("wg-dashboard.ini")
        [[ -f "$INSTALL_DIR/src/ssl-tls.ini" ]] && backup_items+=("ssl-tls.ini")

        info "Respaldando la configuración existente..."
        tar -czf "$backup_file" -C "$INSTALL_DIR/src" "${backup_items[@]}"
        chmod 600 "$backup_file"
        ok "Respaldo creado: $backup_file"
    fi
}

install_wgdashboard() {
    if systemctl list-unit-files 2>/dev/null | grep -q '^wg-dashboard.service'; then
        systemctl stop wg-dashboard.service 2>/dev/null || true
    fi

    if [[ -d "$INSTALL_DIR/.git" ]]; then
        backup_existing_wgd
        info "Actualizando el repositorio existente..."
        git -C "$INSTALL_DIR" fetch --tags --force origin
        git -C "$INSTALL_DIR" checkout -f "$RESOLVED_WGD_VERSION"
    elif [[ -e "$INSTALL_DIR" ]]; then
        fatal "$INSTALL_DIR existe, pero no es un repositorio Git válido. Muévelo o cambia INSTALL_DIR."
    else
        info "Descargando WGDashboard ${RESOLVED_WGD_VERSION}..."
        git clone --depth 1 --branch "$RESOLVED_WGD_VERSION" "$GITHUB_REPO" "$INSTALL_DIR"
    fi

    cd "$INSTALL_DIR/src"
    chmod 750 ./wgd.sh

    info "Ejecutando el instalador oficial de WGDashboard..."
    # El salto de línea selecciona automáticamente el mirror recomendado de PyPI.
    printf '\n' | ./wgd.sh install

    [[ -x "$INSTALL_DIR/src/venv/bin/gunicorn" ]] \
        || fatal "No se creó correctamente el entorno Python de WGDashboard."

    # El instalador oficial aplica 755; se corrige para proteger claves privadas.
    install -d -m 700 /etc/wireguard
    find /etc/wireguard -type d -exec chmod 700 {} +
    find /etc/wireguard -type f -exec chmod 600 {} +
    ok "WGDashboard instalado en $INSTALL_DIR."
}

configure_forwarding() {
    info "Activando reenvío IP persistente..."
    cat > /etc/sysctl.d/99-wireguard-forwarding.conf <<EOF_SYSCTL
# Administrado por instalar_wireguard_wgdashboard.sh
net.ipv4.ip_forward=1
EOF_SYSCTL

    if is_true "$ENABLE_IPV6_FORWARDING"; then
        echo 'net.ipv6.conf.all.forwarding=1' >> /etc/sysctl.d/99-wireguard-forwarding.conf
    fi

    chmod 644 /etc/sysctl.d/99-wireguard-forwarding.conf
    sysctl --system >/dev/null
    [[ "$(sysctl -n net.ipv4.ip_forward)" == "1" ]] || fatal "No se pudo habilitar net.ipv4.ip_forward."
    ok "Reenvío IP habilitado."
}

detect_external_interface() {
    EXTERNAL_INTERFACE="$(ip -4 route show default | awk 'NR==1 {print $5}')"
    [[ -n "$EXTERNAL_INTERFACE" ]] || fatal "No se pudo detectar la interfaz de salida a Internet."
    [[ "$EXTERNAL_INTERFACE" =~ ^[a-zA-Z0-9_.:-]+$ ]] || fatal "Interfaz de red inválida: $EXTERNAL_INTERFACE"
    info "Interfaz de salida detectada: $EXTERNAL_INTERFACE"
}

create_initial_wireguard_interface() {
    is_true "$CREATE_INITIAL_INTERFACE" || {
        warn "Creación de ${WG_INTERFACE} omitida por configuración."
        return 0
    }

    validate_port WG_PORT "$WG_PORT"
    validate_ipv4_cidr "$VPN_SUBNET" || fatal "VPN_SUBNET no es una red IPv4 válida: $VPN_SUBNET"
    validate_ipv4_cidr "$SERVER_VPN_ADDRESS" || fatal "SERVER_VPN_ADDRESS no es una dirección IPv4/CIDR válida: $SERVER_VPN_ADDRESS"

    python3 - "$VPN_SUBNET" "$SERVER_VPN_ADDRESS" <<'PY' || fatal "SERVER_VPN_ADDRESS debe pertenecer a VPN_SUBNET."
import ipaddress
import sys
network = ipaddress.ip_network(sys.argv[1], strict=False)
server = ipaddress.ip_interface(sys.argv[2])
raise SystemExit(0 if server.ip in network else 1)
PY

    local conf="/etc/wireguard/${WG_INTERFACE}.conf"
    if [[ -f "$conf" ]]; then
        warn "$conf ya existe; no será reemplazado."
        chmod 600 "$conf"

        local existing_port existing_address
        existing_port="$(awk -F= '/^[[:space:]]*ListenPort[[:space:]]*=/{gsub(/[[:space:]]/,"",$2); print $2; exit}' "$conf")"
        existing_address="$(awk -F= '/^[[:space:]]*Address[[:space:]]*=/{gsub(/[[:space:]]/,"",$2); split($2,a,","); print a[1]; exit}' "$conf")"
        if [[ -n "$existing_port" ]]; then
            WG_PORT="$existing_port"
            validate_port WG_PORT "$WG_PORT"
        fi
        if [[ -n "$existing_address" ]]; then
            SERVER_VPN_ADDRESS="$existing_address"
            VPN_SUBNET="$(python3 - "$existing_address" <<'PY'
import ipaddress
import sys
print(ipaddress.ip_interface(sys.argv[1]).network)
PY
)"
        fi
        info "Se usarán los valores existentes: ${SERVER_VPN_ADDRESS}, red ${VPN_SUBNET}, puerto ${WG_PORT}/UDP."
    else
        info "Creando interfaz inicial ${WG_INTERFACE}..."
        local private_key
        private_key="$(wg genkey)"

        {
            echo '[Interface]'
            echo "Address = ${SERVER_VPN_ADDRESS}"
            echo "ListenPort = ${WG_PORT}"
            echo "PrivateKey = ${private_key}"
            if is_true "$ENABLE_NAT"; then
                echo "PostUp = iptables -C FORWARD -i %i -j ACCEPT 2>/dev/null || iptables -A FORWARD -i %i -j ACCEPT; iptables -C FORWARD -o %i -j ACCEPT 2>/dev/null || iptables -A FORWARD -o %i -j ACCEPT; iptables -t nat -C POSTROUTING -s ${VPN_SUBNET} -o ${EXTERNAL_INTERFACE} -j MASQUERADE 2>/dev/null || iptables -t nat -A POSTROUTING -s ${VPN_SUBNET} -o ${EXTERNAL_INTERFACE} -j MASQUERADE"
                echo "PostDown = iptables -D FORWARD -i %i -j ACCEPT 2>/dev/null || true; iptables -D FORWARD -o %i -j ACCEPT 2>/dev/null || true; iptables -t nat -D POSTROUTING -s ${VPN_SUBNET} -o ${EXTERNAL_INTERFACE} -j MASQUERADE 2>/dev/null || true"
            fi
        } > "$conf"
        chmod 600 "$conf"
        ok "Interfaz creada: $conf"
    fi

    systemctl enable "wg-quick@${WG_INTERFACE}.service" >/dev/null
    if ! systemctl restart "wg-quick@${WG_INTERFACE}.service"; then
        journalctl -u "wg-quick@${WG_INTERFACE}.service" -n 50 --no-pager || true
        fatal "No se pudo iniciar ${WG_INTERFACE}. Revisa la configuración anterior."
    fi
    ok "WireGuard ${WG_INTERFACE} está activo."
}

create_systemd_service() {
    info "Configurando el arranque automático de WGDashboard..."
    cat > /etc/systemd/system/wg-dashboard.service <<EOF_SERVICE
[Unit]
Description=WGDashboard web interface for WireGuard
Documentation=https://docs.wgdashboard.dev/
After=network-online.target wg-quick@${WG_INTERFACE}.service
Wants=network-online.target
ConditionPathIsDirectory=/etc/wireguard

[Service]
Type=forking
WorkingDirectory=${INSTALL_DIR}/src
PIDFile=${INSTALL_DIR}/src/gunicorn.pid
ExecStart=${INSTALL_DIR}/src/wgd.sh start
ExecStop=${INSTALL_DIR}/src/wgd.sh stop
ExecReload=${INSTALL_DIR}/src/wgd.sh restart
TimeoutStartSec=180
TimeoutStopSec=60
Restart=on-failure
RestartSec=5
User=root
Group=root
UMask=0077
PrivateTmp=true
ProtectHome=true
NoNewPrivileges=false

[Install]
WantedBy=multi-user.target
EOF_SERVICE

    chmod 644 /etc/systemd/system/wg-dashboard.service
    systemctl daemon-reload
    systemctl enable wg-dashboard.service >/dev/null
    systemctl restart wg-dashboard.service
    sleep 3

    if ! systemctl is-active --quiet wg-dashboard.service; then
        systemctl status wg-dashboard.service --no-pager || true
        journalctl -u wg-dashboard.service -n 80 --no-pager || true
        fatal "WGDashboard no pudo iniciar como servicio."
    fi
    ok "Servicio wg-dashboard activo y habilitado."
}

configure_wgdashboard_defaults() {
    local ini_file="${INSTALL_DIR}/src/wg-dashboard.ini"
    info "Aplicando puerto web y valores seguros para nuevos peers..."

    local attempt
    for attempt in {1..30}; do
        [[ -f "$ini_file" ]] && break
        sleep 1
    done
    [[ -f "$ini_file" ]] || fatal "WGDashboard no generó $ini_file."

    systemctl stop wg-dashboard.service
    python3 - "$ini_file" "$DASHBOARD_PORT" "$VPN_SUBNET" <<'PY'
import configparser
import os
import sys
import tempfile

path, port, vpn_subnet = sys.argv[1:]
config = configparser.ConfigParser(interpolation=None)
config.optionxform = str
with open(path, "r", encoding="utf-8") as handle:
    config.read_file(handle)

if not config.has_section("Server"):
    config.add_section("Server")
config.set("Server", "app_ip", "0.0.0.0")
config.set("Server", "app_port", port)
config.set("Server", "auth_req", "true")

if not config.has_section("Peers"):
    config.add_section("Peers")
# Split tunnel por defecto: evita que los nuevos peers cambien su IP pública.
config.set("Peers", "peer_endpoint_allowed_ip", vpn_subnet)

fd, tmp_path = tempfile.mkstemp(prefix="wg-dashboard-", suffix=".ini", dir=os.path.dirname(path))
try:
    with os.fdopen(fd, "w", encoding="utf-8") as handle:
        config.write(handle)
        handle.flush()
        os.fsync(handle.fileno())
    os.chmod(tmp_path, 0o600)
    os.replace(tmp_path, path)
finally:
    if os.path.exists(tmp_path):
        os.unlink(tmp_path)
PY
    chmod 600 "$ini_file"
    systemctl start wg-dashboard.service
    sleep 3
    systemctl is-active --quiet wg-dashboard.service \
        || fatal "WGDashboard no inició después de aplicar su configuración."
    ok "WGDashboard configurado en ${DASHBOARD_PORT}/TCP con AllowedIPs=${VPN_SUBNET} por defecto."
}

detect_ssh_details() {
    SSH_SERVER_PORT=""
    SSH_SOURCE_IP=""

    if [[ -n "${SSH_CONNECTION:-}" ]]; then
        # Formato: cliente_ip cliente_puerto servidor_ip servidor_puerto
        IFS=' ' read -r SSH_SOURCE_IP _ _ SSH_SERVER_PORT <<< "$SSH_CONNECTION"
    elif [[ -n "${SSH_CLIENT:-}" ]]; then
        IFS=' ' read -r SSH_SOURCE_IP _ SSH_SERVER_PORT <<< "$SSH_CLIENT"
    fi

    if [[ -z "$SSH_SOURCE_IP" ]]; then
        local who_remote
        who_remote="$(who -m 2>/dev/null | awk '{print $NF}' | tr -d '()' || true)"
        if [[ -n "$who_remote" ]] && validate_ip_or_cidr "$who_remote"; then
            SSH_SOURCE_IP="$who_remote"
        fi
    fi

    if [[ -z "$SSH_SERVER_PORT" ]]; then
        SSH_SERVER_PORT="$(sshd -T 2>/dev/null | awk '$1=="port" {print $2; exit}')"
    fi
    SSH_SERVER_PORT="${SSH_SERVER_PORT:-22}"
}

resolve_dashboard_acl() {
    if [[ "$DASHBOARD_ALLOWED_CIDR" == "auto" ]]; then
        if [[ -n "$SSH_SOURCE_IP" ]]; then
            DASHBOARD_ALLOWED_CIDR="$(normalize_ip_to_cidr "$SSH_SOURCE_IP")"
        else
            DASHBOARD_ALLOWED_CIDR="127.0.0.1/32"
            warn "No se detectó una sesión SSH. El panel quedará accesible por firewall solo desde localhost."
        fi
    elif [[ "$DASHBOARD_ALLOWED_CIDR" != "any" ]]; then
        validate_ip_or_cidr "$DASHBOARD_ALLOWED_CIDR" \
            || fatal "DASHBOARD_ALLOWED_CIDR no es válido: $DASHBOARD_ALLOWED_CIDR"
        DASHBOARD_ALLOWED_CIDR="$(normalize_ip_to_cidr "$DASHBOARD_ALLOWED_CIDR")"
    fi
}

configure_firewall() {
    is_true "$ENABLE_UFW" || {
        warn "UFW no fue configurado. Debes abrir manualmente ${WG_PORT}/UDP y proteger ${DASHBOARD_PORT}/TCP."
        return 0
    }

    validate_port DASHBOARD_PORT "$DASHBOARD_PORT"
    validate_port SSH_SERVER_PORT "$SSH_SERVER_PORT"
    resolve_dashboard_acl

    info "Configurando firewall UFW sin interrumpir SSH..."
    ufw allow "${SSH_SERVER_PORT}/tcp" comment 'SSH administracion' >/dev/null
    ufw allow "${WG_PORT}/udp" comment 'WireGuard VPN' >/dev/null

    if [[ "$DASHBOARD_ALLOWED_CIDR" == "any" ]]; then
        warn "El panel WGDashboard será accesible desde cualquier IP. Cambia de inmediato admin/admin y activa 2FA."
        ufw allow "${DASHBOARD_PORT}/tcp" comment 'WGDashboard web' >/dev/null
    else
        ufw allow from "$DASHBOARD_ALLOWED_CIDR" to any port "$DASHBOARD_PORT" proto tcp \
            comment 'WGDashboard restringido' >/dev/null
    fi

    ufw default deny incoming >/dev/null
    ufw default allow outgoing >/dev/null
    ufw --force enable >/dev/null
    ufw reload >/dev/null

    # UFW puede reconstruir las cadenas de iptables. Se reinicia WireGuard para
    # volver a aplicar de forma limpia sus reglas PostUp/PostDown de NAT y FORWARD.
    if systemctl is-active --quiet "wg-quick@${WG_INTERFACE}.service"; then
        systemctl restart "wg-quick@${WG_INTERFACE}.service"
    fi
    ok "Firewall activo. SSH ${SSH_SERVER_PORT}/TCP, WireGuard ${WG_PORT}/UDP."
}

verify_installation() {
    info "Verificando servicios y puertos..."
    if is_true "$CREATE_INITIAL_INTERFACE" || ip link show "$WG_INTERFACE" >/dev/null 2>&1; then
        systemctl is-active --quiet "wg-quick@${WG_INTERFACE}.service" \
            || fatal "El servicio wg-quick@${WG_INTERFACE} no está activo."
        wg show "$WG_INTERFACE" >/dev/null \
            || fatal "La interfaz ${WG_INTERFACE} no responde a wg show."
    fi
    systemctl is-active --quiet wg-dashboard.service \
        || fatal "El servicio wg-dashboard no está activo."

    ss -lnt | awk '{print $4}' | grep -Eq "(^|:)$DASHBOARD_PORT$" \
        || fatal "WGDashboard no está escuchando en el puerto TCP ${DASHBOARD_PORT}."
    ss -lnu | awk '{print $4}' | grep -Eq "(^|:)$WG_PORT$" \
        || warn "No se detectó el puerto UDP ${WG_PORT} con ss, aunque la interfaz está activa."

    ok "Verificación final completada."
}

run_final_diagnostics() {
    local diag_ok_count=0
    local diag_warn_count=0
    local diag_fail_count=0
    local conf="/etc/wireguard/${WG_INTERFACE}.conf"
    local dashboard_url="http://127.0.0.1:${DASHBOARD_PORT}"
    local http_code=""
    local actual_wg_port=""
    local expected_server_cidr="${SERVER_VPN_ADDRESS}"
    local service_name="wg-quick@${WG_INTERFACE}.service"

    diag_ok() {
        diag_ok_count=$((diag_ok_count + 1))
        printf '\033[1;32m  [CORRECTO]\033[0m %s\n' "$*"
    }

    diag_warning() {
        diag_warn_count=$((diag_warn_count + 1))
        printf '\033[1;33m  [ADVERTENCIA]\033[0m %s\n' "$*"
    }

    diag_failure() {
        diag_fail_count=$((diag_fail_count + 1))
        printf '\033[1;31m  [FALLO]\033[0m %s\n' "$*"
    }

    echo
    echo '=============================================================================='
    echo ' DIAGNÓSTICO AUTOMÁTICO FINAL'
    echo '=============================================================================='

    echo
    echo '1. Sistema y dependencias'
    if [[ -r /etc/os-release ]]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        if [[ "${ID:-}" == "ubuntu" && "${VERSION_ID:-}" == "24.04" ]]; then
            diag_ok "Ubuntu 24.04 detectado."
        elif [[ "${ID:-}" == "ubuntu" ]]; then
            diag_warning "Ubuntu ${VERSION_ID:-desconocido}; el instalador fue diseñado para 24.04."
        else
            diag_failure "El sistema detectado no es Ubuntu."
        fi
    else
        diag_failure "No se pudo leer /etc/os-release."
    fi

    local required_command
    for required_command in wg wg-quick ip ss curl python3 systemctl iptables; do
        if command -v "$required_command" >/dev/null 2>&1; then
            diag_ok "Comando disponible: ${required_command}."
        else
            diag_failure "Falta el comando requerido: ${required_command}."
        fi
    done

    if python3 - <<'PY_VERSION' >/dev/null 2>&1
import sys
raise SystemExit(0 if sys.version_info >= (3, 12) else 1)
PY_VERSION
    then
        diag_ok "Python compatible: $(python3 --version 2>&1)."
    else
        diag_failure "Python 3.12 o superior no está disponible."
    fi

    echo
    echo '2. Reenvío, red y configuración WireGuard'
    if [[ "$(sysctl -n net.ipv4.ip_forward 2>/dev/null || true)" == "1" ]]; then
        diag_ok "net.ipv4.ip_forward está habilitado."
    else
        diag_failure "net.ipv4.ip_forward no está habilitado."
    fi

    if ip link show "$EXTERNAL_INTERFACE" >/dev/null 2>&1; then
        diag_ok "Interfaz de salida existente: ${EXTERNAL_INTERFACE}."
    else
        diag_failure "No existe la interfaz de salida ${EXTERNAL_INTERFACE}."
    fi

    if [[ -f "$conf" ]]; then
        diag_ok "Configuración encontrada: ${conf}."
        local conf_mode
        conf_mode="$(stat -c '%a' "$conf" 2>/dev/null || true)"
        if [[ "$conf_mode" == "600" ]]; then
            diag_ok "Permisos seguros en ${conf}: 600."
        else
            diag_warning "Permisos de ${conf}: ${conf_mode:-desconocidos}; se recomienda 600."
        fi
    else
        diag_failure "No existe ${conf}."
    fi

    if systemctl is-enabled --quiet "$service_name" 2>/dev/null; then
        diag_ok "${service_name} está habilitado al iniciar."
    else
        diag_failure "${service_name} no está habilitado al iniciar."
    fi

    if systemctl is-active --quiet "$service_name" 2>/dev/null; then
        diag_ok "${service_name} está activo."
    else
        diag_failure "${service_name} no está activo."
    fi

    if ip link show "$WG_INTERFACE" >/dev/null 2>&1; then
        diag_ok "Interfaz ${WG_INTERFACE} creada y disponible."
    else
        diag_failure "La interfaz ${WG_INTERFACE} no existe."
    fi

    if wg show "$WG_INTERFACE" >/dev/null 2>&1; then
        diag_ok "WireGuard responde correctamente en ${WG_INTERFACE}."
        actual_wg_port="$(wg show "$WG_INTERFACE" listen-port 2>/dev/null || true)"
        if [[ "$actual_wg_port" == "$WG_PORT" ]]; then
            diag_ok "WireGuard escucha en ${WG_PORT}/UDP."
        else
            diag_failure "Puerto WireGuard esperado ${WG_PORT}/UDP; detectado ${actual_wg_port:-ninguno}."
        fi
    else
        diag_failure "wg show no puede consultar ${WG_INTERFACE}."
    fi

    if ip -4 -o addr show dev "$WG_INTERFACE" 2>/dev/null | awk '{print $4}' | grep -Fxq "$expected_server_cidr"; then
        diag_ok "Dirección VPN asignada: ${expected_server_cidr}."
    else
        diag_warning "No se encontró exactamente ${expected_server_cidr} en ${WG_INTERFACE}."
    fi

    if ss -H -lnu 2>/dev/null | awk '{print $4}' | grep -Eq "(^|:)${WG_PORT}$"; then
        diag_ok "Puerto UDP ${WG_PORT} visible en el sistema."
    else
        diag_failure "El puerto UDP ${WG_PORT} no aparece escuchando."
    fi

    if is_true "$ENABLE_NAT"; then
        if iptables -t nat -C POSTROUTING -s "$VPN_SUBNET" -o "$EXTERNAL_INTERFACE" -j MASQUERADE >/dev/null 2>&1; then
            diag_ok "Regla NAT MASQUERADE activa para ${VPN_SUBNET}."
        else
            diag_failure "No se encontró la regla NAT MASQUERADE para ${VPN_SUBNET}."
        fi

        if iptables -C FORWARD -i "$WG_INTERFACE" -j ACCEPT >/dev/null 2>&1; then
            diag_ok "Regla FORWARD de entrada desde ${WG_INTERFACE} activa."
        else
            diag_failure "Falta la regla FORWARD de entrada desde ${WG_INTERFACE}."
        fi

        if iptables -C FORWARD -o "$WG_INTERFACE" -j ACCEPT >/dev/null 2>&1; then
            diag_ok "Regla FORWARD de salida hacia ${WG_INTERFACE} activa."
        else
            diag_failure "Falta la regla FORWARD de salida hacia ${WG_INTERFACE}."
        fi
    else
        diag_warning "NAT fue deshabilitado mediante ENABLE_NAT=false."
    fi

    echo
    echo '3. WGDashboard'
    if [[ -d "$INSTALL_DIR/src" ]]; then
        diag_ok "WGDashboard instalado en ${INSTALL_DIR}."
    else
        diag_failure "No existe el directorio ${INSTALL_DIR}/src."
    fi

    if [[ -x "$INSTALL_DIR/src/venv/bin/gunicorn" ]]; then
        diag_ok "Entorno virtual y Gunicorn disponibles."
    else
        diag_failure "No se encontró Gunicorn dentro del entorno virtual."
    fi

    if [[ -f "$INSTALL_DIR/src/wg-dashboard.ini" ]]; then
        diag_ok "Archivo wg-dashboard.ini disponible."
        local configured_port configured_allowed_ips
        configured_port="$(python3 - "$INSTALL_DIR/src/wg-dashboard.ini" <<'PY_INI_PORT' 2>/dev/null || true
import configparser, sys
c = configparser.ConfigParser(interpolation=None)
c.read(sys.argv[1], encoding='utf-8')
print(c.get('Server', 'app_port', fallback=''))
PY_INI_PORT
)"
        configured_allowed_ips="$(python3 - "$INSTALL_DIR/src/wg-dashboard.ini" <<'PY_INI_ALLOWED' 2>/dev/null || true
import configparser, sys
c = configparser.ConfigParser(interpolation=None)
c.read(sys.argv[1], encoding='utf-8')
print(c.get('Peers', 'peer_endpoint_allowed_ip', fallback=''))
PY_INI_ALLOWED
)"
        if [[ "$configured_port" == "$DASHBOARD_PORT" ]]; then
            diag_ok "Puerto ${DASHBOARD_PORT} guardado en wg-dashboard.ini."
        else
            diag_failure "wg-dashboard.ini tiene puerto ${configured_port:-vacío}, se esperaba ${DASHBOARD_PORT}."
        fi
        if [[ "$configured_allowed_ips" == "$VPN_SUBNET" ]]; then
            diag_ok "Split tunnel predeterminado configurado: ${VPN_SUBNET}."
        else
            diag_warning "AllowedIPs predeterminado detectado: ${configured_allowed_ips:-vacío}."
        fi
    else
        diag_failure "No existe wg-dashboard.ini."
    fi

    if systemctl is-enabled --quiet wg-dashboard.service 2>/dev/null; then
        diag_ok "wg-dashboard.service está habilitado al iniciar."
    else
        diag_failure "wg-dashboard.service no está habilitado al iniciar."
    fi

    if systemctl is-active --quiet wg-dashboard.service 2>/dev/null; then
        diag_ok "wg-dashboard.service está activo."
    else
        diag_failure "wg-dashboard.service no está activo."
    fi

    if ss -H -lnt 2>/dev/null | awk '{print $4}' | grep -Eq "(^|:)${DASHBOARD_PORT}$"; then
        diag_ok "WGDashboard escucha en ${DASHBOARD_PORT}/TCP."
    else
        diag_failure "WGDashboard no escucha en ${DASHBOARD_PORT}/TCP."
    fi

    http_code="$(curl -sS -o /dev/null --max-time 10 -w '%{http_code}' "$dashboard_url" 2>/dev/null || true)"
    case "$http_code" in
        200|301|302|303|307|308|401|403)
            diag_ok "Respuesta HTTP local de WGDashboard: ${http_code}."
            ;;
        000|'')
            diag_failure "WGDashboard no respondió localmente en ${dashboard_url}."
            ;;
        *)
            diag_warning "WGDashboard respondió con HTTP ${http_code} en ${dashboard_url}."
            ;;
    esac

    echo
    echo '4. Firewall y persistencia'
    if is_true "$ENABLE_UFW"; then
        if LC_ALL=C ufw status 2>/dev/null | grep -q '^Status: active'; then
            diag_ok "UFW está activo."
        else
            diag_failure "UFW no está activo."
        fi

        if LC_ALL=C ufw status 2>/dev/null | grep -Eq "(^|[[:space:]])${WG_PORT}/udp([[:space:]]|$)"; then
            diag_ok "UFW contiene una regla para ${WG_PORT}/UDP."
        else
            diag_failure "UFW no muestra una regla para ${WG_PORT}/UDP."
        fi

        if LC_ALL=C ufw status 2>/dev/null | grep -Eq "(^|[[:space:]])${DASHBOARD_PORT}/tcp([[:space:]]|$)|(^|[[:space:]])${DASHBOARD_PORT}([[:space:]]|$)"; then
            diag_ok "UFW contiene una regla para el panel ${DASHBOARD_PORT}/TCP."
        else
            diag_failure "UFW no muestra una regla para el panel ${DASHBOARD_PORT}/TCP."
        fi
    else
        diag_warning "UFW fue omitido mediante ENABLE_UFW=false."
    fi

    echo
    echo '5. Eventos recientes'
    local dashboard_errors wireguard_errors
    dashboard_errors="$(journalctl -u wg-dashboard.service --since '-10 minutes' -p warning --no-pager 2>/dev/null | grep -Ev '^-- No entries --$|^$' | tail -n 10 || true)"
    wireguard_errors="$(journalctl -u "$service_name" --since '-10 minutes' -p warning --no-pager 2>/dev/null | grep -Ev '^-- No entries --$|^$' | tail -n 10 || true)"

    if [[ -z "$dashboard_errors" ]]; then
        diag_ok "Sin advertencias recientes en wg-dashboard.service."
    else
        diag_warning "WGDashboard registra eventos recientes; revisa el extracto inferior."
        printf '%s\n' "$dashboard_errors" | sed 's/^/      /'
    fi

    if [[ -z "$wireguard_errors" ]]; then
        diag_ok "Sin advertencias recientes en ${service_name}."
    else
        diag_warning "WireGuard registra eventos recientes; revisa el extracto inferior."
        printf '%s\n' "$wireguard_errors" | sed 's/^/      /'
    fi

    echo
    echo '-------------------------------------------------------------------------------'
    printf ' RESULTADO: %d correctos | %d advertencias | %d fallos críticos\n' \
        "$diag_ok_count" "$diag_warn_count" "$diag_fail_count"
    echo '-------------------------------------------------------------------------------'

    DIAGNOSTIC_FAILURES="$diag_fail_count"
    DIAGNOSTIC_WARNINGS="$diag_warn_count"
}

print_summary() {
    local server_ip public_ip public_key
    server_ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
    public_ip="$(curl -4fsS --max-time 5 https://api.ipify.org 2>/dev/null || true)"
    public_key="$(wg show "$WG_INTERFACE" public-key 2>/dev/null || true)"

    cat <<EOF_SUMMARY

===============================================================================
 INSTALACIÓN COMPLETADA
===============================================================================
 WGDashboard:       ${RESOLVED_WGD_VERSION}
 Directorio:        ${INSTALL_DIR}
 Panel local/LAN:   http://${server_ip:-IP_DEL_SERVIDOR}:${DASHBOARD_PORT}
 Usuario inicial:   admin
 Contraseña inicial: admin   <-- CÁMBIALA INMEDIATAMENTE
 Acceso firewall:   ${DASHBOARD_ALLOWED_CIDR}

 WireGuard:         ${WG_INTERFACE}
 Puerto UDP:        ${WG_PORT}
 Red VPN:           ${VPN_SUBNET}
 IP servidor VPN:   ${SERVER_VPN_ADDRESS}
 IP pública:        ${public_ip:-no detectada}
 Clave pública:     ${public_key:-no disponible}
 Interfaz Internet: ${EXTERNAL_INTERFACE}

 Registro:          ${LOG_FILE}
===============================================================================

COMANDOS ÚTILES
  systemctl status wg-dashboard --no-pager
  systemctl status wg-quick@${WG_INTERFACE} --no-pager
  wg show
  ufw status numbered
  journalctl -u wg-dashboard -f

SEGURIDAD IMPORTANTE
  1. Entra al panel y cambia inmediatamente admin/admin.
  2. Activa autenticación de dos factores desde WGDashboard.
  3. Para que un peer NO cambie su IP pública, usa AllowedIPs=${VPN_SUBNET}
     en el cliente. No uses AllowedIPs=0.0.0.0/0 salvo que quieras túnel completo.
  4. Para acceder al panel desde otra IP, agrega una regla específica:
     ufw allow from IP_AUTORIZADA/32 to any port ${DASHBOARD_PORT} proto tcp

EOF_SUMMARY
}

main() {
    require_root
    check_ubuntu
    install_packages
    check_network
    validate_port DASHBOARD_PORT "$DASHBOARD_PORT"
    validate_port WG_PORT "$WG_PORT"
    resolve_wgd_version
    detect_external_interface
    detect_ssh_details
    install_wgdashboard
    configure_forwarding
    create_initial_wireguard_interface
    configure_firewall
    create_systemd_service
    configure_wgdashboard_defaults
    verify_installation
    print_summary
    run_final_diagnostics

    if (( DIAGNOSTIC_FAILURES > 0 )); then
        echo
        echo "[ERROR] El diagnóstico detectó ${DIAGNOSTIC_FAILURES} fallo(s) crítico(s)."
        echo "[ERROR] Revisa el detalle anterior y el registro: ${LOG_FILE}"
        exit 2
    fi

    if (( DIAGNOSTIC_WARNINGS > 0 )); then
        echo
        warn "Instalación operativa con ${DIAGNOSTIC_WARNINGS} advertencia(s). Revisa el diagnóstico."
    else
        echo
        ok "Instalación y diagnóstico completados sin errores ni advertencias."
    fi
}

main "$@"
