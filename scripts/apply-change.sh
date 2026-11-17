#!/usr/bin/env bash
# -------------------------------------------------------------------
# Traduce parámetros de un CI (variables de entorno) a una llamada a
# opa_delivery.py. Mismo contrato para Jenkins, GitHub Actions, GitLab...
#
#   OPERATION        validate-only | add-endpoint | remove-endpoint |
#                    add-caller | remove-caller | add-public-path |
#                    remove-public-path | apply-spec
#   CALLER           valor del claim (ej. guest)
#   ENDPOINT_PATH    path o glob (ej. /api/server/v1, /api/items/*)
#   METHODS          GET,POST,...
#   DESCRIPTION      descripción del caller (opcional)
#   CHANGE_SPEC_FILE ruta a un spec JSON (OPERATION=apply-spec)
# -------------------------------------------------------------------
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

OPERATION="${OPERATION:-validate-only}"
cmd=(python3 tools/opa_delivery.py)

case "$OPERATION" in
  validate-only)
    echo "==> OPERATION=validate-only: no se modifica data.authz"
    exit 0
    ;;
  apply-spec)
    [ -n "${CHANGE_SPEC_FILE:-}" ] || { echo "CHANGE_SPEC_FILE es obligatorio para apply-spec" >&2; exit 2; }
    cmd+=(apply --spec "$CHANGE_SPEC_FILE")
    ;;
  add-endpoint|remove-endpoint)
    cmd+=("$OPERATION" --caller "${CALLER:?CALLER es obligatorio}" --path "${ENDPOINT_PATH:?ENDPOINT_PATH es obligatorio}")
    [ -n "${METHODS:-}" ] && cmd+=(--methods "$METHODS")
    [ "$OPERATION" = "add-endpoint" ] && [ -n "${DESCRIPTION:-}" ] && cmd+=(--description "$DESCRIPTION")
    ;;
  add-caller)
    cmd+=(add-caller --caller "${CALLER:?CALLER es obligatorio}")
    [ -n "${DESCRIPTION:-}" ] && cmd+=(--description "$DESCRIPTION")
    ;;
  remove-caller)
    cmd+=(remove-caller --caller "${CALLER:?CALLER es obligatorio}")
    ;;
  add-public-path|remove-public-path)
    cmd+=("$OPERATION" --path "${ENDPOINT_PATH:?ENDPOINT_PATH es obligatorio}")
    ;;
  *)
    echo "OPERATION inválida: '$OPERATION'" >&2
    exit 2
    ;;
esac

echo "==> ${cmd[*]}"
"${cmd[@]}"
echo
python3 tools/opa_delivery.py list
