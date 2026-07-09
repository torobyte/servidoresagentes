#!/bin/sh
# Torobyte installer bootstrap - intenta GitHub raw primero (TLS moderno)
# y usa monitor.torobyte.com como fallback. Compatible con macOS antiguos.
set -e
OS="${1:-linux}"
ACTION="${2:-install}"
ORIGIN="https://monitor.torobyte.com"
SOURCES="https://raw.githubusercontent.com/torobyte/servidoresagentes/main/agents $ORIGIN/api/public/agents"
tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT

download() {
  url="$1/$OS.sh"
  # Intento 1: curl estándar (TLS moderno)
  if curl -fsSL --connect-timeout 8 --max-time 40 -o "$tmp" "$url" 2>/dev/null; then return 0; fi
  # Intento 2: curl forzando TLS 1.2
  if curl -fsSL --tlsv1.2 --connect-timeout 8 --max-time 40 -o "$tmp" "$url" 2>/dev/null; then return 0; fi
  # Intento 3: curl aceptando certificados (último recurso)
  if curl -fsSLk --connect-timeout 8 --max-time 40 -o "$tmp" "$url" 2>/dev/null; then return 0; fi
  # Intento 4: wget si está disponible
  if command -v wget >/dev/null 2>&1 && wget -q --no-check-certificate -O "$tmp" "$url" 2>/dev/null; then return 0; fi
  return 1
}

ok=0
for src in $SOURCES; do
  if download "$src"; then ok=1; break; fi
  echo "no se pudo descargar desde $src, probando siguiente..." >&2
done
[ "$ok" = "1" ] || { echo "Error: no se pudo descargar el agente para $OS" >&2; exit 1; }
[ -s "$tmp" ] || { echo "Descarga vacia" >&2; exit 1; }
case $(head -c2 "$tmp") in
  "#!"*|"# ") ;;
  "<"*) echo "Descarga devolvio HTML" >&2; exit 1 ;;
  *) echo "Script invalido" >&2; exit 1 ;;
esac
if [ "$ACTION" = "install" ]; then
  [ -z "$TOKEN" ] && { echo "Falta TOKEN" >&2; exit 1; }
  [ -z "$URL" ] && { echo "Falta URL" >&2; exit 1; }
  sudo env TOKEN="$TOKEN" URL="$URL" sh "$tmp" install
else
  sudo sh "$tmp" "$ACTION"
fi
