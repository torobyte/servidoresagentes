#!/bin/sh
set -e
OS="${1:-linux}"
ACTION="${2:-install}"
ORIGIN="https://monitor.torobyte.com"
tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT
http=$(curl -fsSL -w "%{http_code}" -o "$tmp" "$ORIGIN/api/public/agents/$OS.sh")
[ "$http" = "200" ] || { echo "Error HTTP $http" >&2; exit 1; }
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
