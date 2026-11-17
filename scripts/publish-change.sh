#!/usr/bin/env bash
# -------------------------------------------------------------------
# Publica un cambio de data/políticas OPA según el modo de delivery.
# Es agnóstico del CI: Jenkins, GitHub Actions, GitLab, etc. solo lo invocan.
#
#   DELIVERY_MODE=gitops    -> crea rama + commit + push + Pull Request.
#                              Flux despliega cuando el PR se mergea.
#   DELIVERY_MODE=pipeline  -> commit + push directo a BASE_BRANCH y
#                              despliega con kubectl (make deploy-opa).
#
# Variables:
#   DELIVERY_MODE   gitops | pipeline                (default: gitops)
#   BASE_BRANCH     rama destino                     (default: main)
#   CHANGE_BRANCH   rama del PR en modo gitops       (default: opa-delivery/<timestamp>)
#   COMMIT_MESSAGE  mensaje de commit / título PR    (default: chore(opa): update authz data)
#   CHANGE_AUTHOR   quién solicitó el cambio (texto para el PR)
#   GIT_REMOTE      remoto git                       (default: origin)
#   GH_TOKEN        si existe y hay `gh`, se abre el PR automáticamente
#   SKIP_DEPLOY     true -> en modo pipeline no ejecuta kubectl
#
# La autenticación de git (push) la provee el CI (credential helper,
# token de actions/checkout, etc.).
# -------------------------------------------------------------------
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

DELIVERY_MODE="${DELIVERY_MODE:-gitops}"
BASE_BRANCH="${BASE_BRANCH:-main}"
CHANGE_BRANCH="${CHANGE_BRANCH:-opa-delivery/$(date +%Y%m%d%H%M%S)}"
COMMIT_MESSAGE="${COMMIT_MESSAGE:-chore(opa): update authz data}"
CHANGE_AUTHOR="${CHANGE_AUTHOR:-ci}"
GIT_REMOTE="${GIT_REMOTE:-origin}"
SKIP_DEPLOY="${SKIP_DEPLOY:-false}"
# Solo se versionan cambios dentro de las políticas
TRACKED_PATHS=(policies)

git config user.name  >/dev/null 2>&1 || git config user.name  "opa-delivery-bot"
git config user.email >/dev/null 2>&1 || git config user.email "opa-delivery-bot@users.noreply.local"

if git diff --quiet -- "${TRACKED_PATHS[@]}" && \
   [ -z "$(git ls-files --others --exclude-standard -- "${TRACKED_PATHS[@]}")" ]; then
  echo "==> Sin cambios en ${TRACKED_PATHS[*]}: nada que publicar."
  exit 0
fi

echo "==> Cambios a publicar:"
git --no-pager diff --stat -- "${TRACKED_PATHS[@]}"

SUMMARY="$(python3 tools/opa_delivery.py list)"

case "$DELIVERY_MODE" in
  gitops)
    echo "==> Modo GitOps: rama ${CHANGE_BRANCH} -> PR hacia ${BASE_BRANCH}"
    git checkout -B "$CHANGE_BRANCH"
    git add -- "${TRACKED_PATHS[@]}"
    git commit -m "$COMMIT_MESSAGE" -m "Solicitado por: ${CHANGE_AUTHOR}"
    git push -u "$GIT_REMOTE" "$CHANGE_BRANCH"

    BODY="$(printf 'Cambio generado por opa-delivery.\n\nSolicitado por: %s\n\nEstado resultante de `data.authz`:\n\n```\n%s\n```\n\nAl mergear, Flux aplica `deploy/opa` en el cluster.\n' "$CHANGE_AUTHOR" "$SUMMARY")"
    if command -v gh >/dev/null 2>&1 && [ -n "${GH_TOKEN:-}" ]; then
      gh pr create --base "$BASE_BRANCH" --head "$CHANGE_BRANCH" \
        --title "$COMMIT_MESSAGE" --body "$BODY"
    else
      echo "==> 'gh' o GH_TOKEN no disponibles: crea el PR ${CHANGE_BRANCH} -> ${BASE_BRANCH} manualmente."
    fi
    ;;

  pipeline)
    echo "==> Modo pipeline: commit directo a ${BASE_BRANCH} + deploy con kubectl"
    git add -- "${TRACKED_PATHS[@]}"
    git commit -m "$COMMIT_MESSAGE" -m "Solicitado por: ${CHANGE_AUTHOR}"
    # Rebase para no pisar cambios concurrentes de otros pipelines
    git pull --rebase "$GIT_REMOTE" "$BASE_BRANCH"
    git push "$GIT_REMOTE" "HEAD:${BASE_BRANCH}"

    if [ "$SKIP_DEPLOY" = "true" ]; then
      echo "==> SKIP_DEPLOY=true: no se despliega."
    else
      make deploy-opa
    fi
    ;;

  *)
    echo "DELIVERY_MODE inválido: '${DELIVERY_MODE}' (usa gitops | pipeline)" >&2
    exit 2
    ;;
esac
