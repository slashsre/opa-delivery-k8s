# OPA Delivery: comandos y set de pruebas

Guía para validar el delivery de punta a punta, desde lo más rápido (sin cluster) hasta los dos
modos de despliegue con el proyecto `envoy-opa-integration` (microservicios + Envoy) en KinD.

| Nivel | Qué valida | Dónde | Necesita |
|-------|-----------|-------|----------|
| [1. Política y CLI](#1-política-y-cli-sin-cluster) | Rego, esquema, formato, CLI | delivery | `python3`, `make`, `curl` |
| [2. Artefactos](#2-artefactos-render-bundle-y-flux-sin-cluster) | Kustomize, bundle, Flux build | delivery | `kubectl`, `flux` |
| [3. Simulación de pipeline consumidor](#3-simulación-de-pipeline-consumidor-sin-cluster) | Checkout + cambio + publicación en ambos modos | delivery | `git` |
| [4. Modo pipeline en KinD](#4-modo-pipeline-en-kind) | Cambio → kubectl → Envoy/OPA autoriza | ambos repos | Docker, `kind` |
| [5. Modo GitOps en KinD](#5-modo-gitops-en-kind-flux) | Cambio → PR/merge → Flux → OPA | ambos repos | + `helm`, `flux`, remoto del delivery |
| [6. CI consumidor](#6-ci-consumidor-jenkins--github-actions) | Jenkinsfile y workflow de envoy-opa | envoy-opa | Jenkins / GitHub |

> Los niveles 1 a 3 se ejecutaron en la rama `feature/delivery-integration` y todos pasaron.
> Los niveles 4 a 6 quedan pendientes de correr en un cluster o CI real.

Rutas usadas abajo:

```bash
DELIVERY=~/repos/opa-delivery-k8s          # git clone https://github.com/slashsre/opa-delivery-k8s.git
ENVOY_OPA=~/repos/envoy-opa-integration     # git clone https://github.com/slashsre/envoy-opa-integration.git
```

---

## 0. Requisitos

```bash
cd $DELIVERY
python3 --version          # 3.8+
make opa-bin               # descarga OPA 0.17.3 a .bin/ si no hay 'opa' en el PATH
kubectl version --client
flux version --client      # solo GitOps
helm version               # solo GitOps (Flux Operator)
```

En Apple Silicon, OPA 0.17.3 solo existe para amd64 y corre con Rosetta.

---

## 1. Política y CLI (sin cluster)

```bash
cd $DELIVERY
make test                  # = cli-test + policy-check
#   cli-test          20 tests del CLI (tools/test_opa_delivery.py)
#   policy-validate   esquema de policies/authz/data.json
#   policy-fmt-check  opa fmt
#   policy-test       opa check + opa test -v
```

Resultado esperado: `Ran 20 tests ... OK` y `PASS: 14/14`.

### Tests de la política (`policies/envoy/authz/policy_test.rego`)

| Test | Caso | Esperado |
|------|------|----------|
| `test_data_health_is_public` | `GET /health` sin token | allow |
| `test_data_root_is_public` | `GET /` sin token | allow |
| `test_data_server_without_token_denied` | `GET /api/server/v1` sin token | deny |
| `test_data_server_guest_allowed` | `GET /api/server/v1` rol `guest` | allow |
| `test_data_client_guest_post_with_query_allowed` | `POST /api/client/v1?target=...` rol `guest` | allow |
| `test_data_server_unknown_role_denied` | `GET /api/server/v1` rol `intruder` | deny |
| `test_engine_glob_endpoint_allowed` | `/api/items/*` contra `/api/items/42` | allow |
| `test_engine_glob_does_not_cross_segments` | `/api/items/*` contra `/api/items/42/details` | deny |
| `test_engine_method_not_allowed` | `DELETE` no autorizado | deny |
| `test_engine_unknown_caller_denied` | caller fuera de la data | deny |
| `test_engine_invalid_signature_denied` | JWT firmado con otra clave | deny |
| `test_engine_non_bearer_scheme_denied` | `Basic <jwt>` | deny |
| `test_engine_public_glob` | public path `/health*` contra `/healthz` | allow |
| `test_engine_custom_caller_claim` | `caller_claim = sub` | allow |

Los `test_data_*` validan la data real. Si un cambio quita el acceso de `guest`, fallan y
bloquean el PR o el pipeline (es intencional). Los `test_engine_*` usan una data fija.

### Tests del CLI (`tools/test_opa_delivery.py`)

| Grupo | Casos |
|-------|-------|
| Data del repo | `data.json` válido y en formato canónico (diffs limpios) |
| Operaciones | add-endpoint crea el caller / fusiona métodos / es idempotente; remove de algunos métodos / del último método / del endpoint completo / inexistente (sin cambios); add y remove caller; public paths; caller_claim; apply-spec; dry-run sin escribir |
| Validaciones | path sin `/`, método inválido, falta `--methods`, caller inválido, spec inválido, `validate` detecta errores. En todos los casos falla sin escribir |

### Pruebas manuales del CLI

```bash
cp policies/authz/data.json /tmp/authz.json
D="python3 tools/opa_delivery.py --data /tmp/authz.json"

$D apply --spec examples/changes/example.json       # crea admin + endpoints
$D apply --spec examples/changes/example.json       # "Sin cambios"
$D remove-endpoint --caller admin --path /api/server/v1 --methods DELETE
$D --dry-run remove-caller --caller admin
$D list
$D add-endpoint --caller guest --path api --methods GET     # ERROR (path sin '/')
```

### Prueba negativa del gate

```bash
make policy-change ARGS='remove-endpoint --caller guest --path /api/server/v1'
make test                     # FAIL: test_data_server_guest_allowed
git checkout -- policies/authz/data.json
```

---

## 2. Artefactos: render, bundle y Flux (sin cluster)

```bash
make policy-render            # dist/opa-manifests.yaml
grep -E 'name: opa-(policies|config)-' dist/opa-manifests.yaml     # nombres con hash

make policy-bundle            # dist/opa-bundle.tar.gz: authz/data.json + envoy/authz/policy.rego

flux build kustomization opa --path ./deploy/opa \
  --kustomization-file deploy/flux/clusters/kind/opa.yaml --dry-run | grep -E '^kind:'
kubectl kustomize deploy/flux/clusters/kind
```

Un cambio de data cambia el hash, y eso fuerza el rollout de OPA:

```bash
kubectl kustomize deploy/opa | grep -m1 'name: opa-policies-'
make policy-change ARGS='add-public-path --path /metrics'
kubectl kustomize deploy/opa | grep -m1 'name: opa-policies-'      # hash distinto
git checkout -- policies/authz/data.json
```

OPA real con el bundle y un JWT del POC:

```bash
.bin/opa-0.17.3 run --server --addr=127.0.0.1:18181 -b dist/opa-bundle.tar.gz &
TOKEN=$($ENVOY_OPA/1.-core/jwt-token.py --raw)

curl -s -X POST 127.0.0.1:18181/v1/data/envoy/authz/allow -d "{\"input\":{\"attributes\":{\"request\":{\"http\":{\"method\":\"GET\",\"path\":\"/api/server/v1\",\"headers\":{\"authorization\":\"Bearer $TOKEN\"}}}}}}"
# {"result":true}
curl -s -X POST 127.0.0.1:18181/v1/data/envoy/authz/allow -d '{"input":{"attributes":{"request":{"http":{"method":"GET","path":"/api/server/v1","headers":{}}}}}}'
# {"result":false}
kill %1
```

---

## 3. Simulación de pipeline consumidor (sin cluster)

Reproduce lo que hacen el Jenkinsfile y el workflow de envoy-opa: checkout del repo delivery en
`opa-delivery/`, el cambio, las pruebas y la publicación. Usa un remoto local, sin tocar GitHub
ni el cluster.

```bash
SB=$(mktemp -d) && cd $SB
git init -q --bare delivery.git
rsync -a --exclude .git --exclude dist $DELIVERY/ seed/
(cd seed && git init -q -b main && git add -A && git commit -qm seed && git push -q ../delivery.git main)
git clone -q delivery.git opa-delivery && cd opa-delivery

# --- Modo GitOps: rama + push (sin GH_TOKEN, no abre PR) ---
OPERATION=add-endpoint CALLER=admin ENDPOINT_PATH=/api/server/v1 METHODS=GET scripts/apply-change.sh
make test
DELIVERY_MODE=gitops CHANGE_BRANCH=opa-delivery/envoy-opa-1 scripts/publish-change.sh
git -C ../delivery.git branch                # aparece opa-delivery/envoy-opa-1

# --- Idempotencia ---
OPERATION=add-endpoint CALLER=admin ENDPOINT_PATH=/api/server/v1 METHODS=GET scripts/apply-change.sh  # "Sin cambios"
scripts/publish-change.sh                    # "nada que publicar"

# --- validate-only ---
git checkout -q main && OPERATION=validate-only scripts/apply-change.sh

# --- Modo pipeline: spec en lote + push a main (sin kubectl) ---
CHANGE_SPEC_FILE=$PWD/examples/changes/example.json OPERATION=apply-spec scripts/apply-change.sh
make test
DELIVERY_MODE=pipeline SKIP_DEPLOY=true scripts/publish-change.sh
git -C ../delivery.git log --oneline main    # nuevo commit "chore(opa): ..."

# --- Cambio que rompe el gate: el CI no llega a publicar ---
OPERATION=remove-endpoint CALLER=guest ENDPOINT_PATH=/api/server/v1 scripts/apply-change.sh
make test                                    # FAIL: 1/14 → rc ≠ 0

cd / && rm -rf $SB
```

---

## 4. Modo pipeline en KinD

Los microservicios los despliega envoy-opa y OPA lo despliega el delivery. **No** ejecutes
`make install` ni `make deploy-opa` en envoy-opa: instalan la versión anterior de OPA, con
kube-mgmt, en el mismo namespace.

```bash
# Cluster + imágenes + microservicios (sin OPA)
cd $ENVOY_OPA
make delete-opa 2>/dev/null || true       # si había un OPA anterior
make cluster-up images deploy-apps

# OPA + políticas desde el delivery
cd $DELIVERY
make deploy-opa                           # kubectl apply -k deploy/opa + rollout
kubectl -n opa get deploy,cm              # opa-policies-<hash>, opa-config-<hash>

# Pruebas en vivo
cd $ENVOY_OPA && make test-auth           # 4/4: health 200, sin token 403, guest 200, admin 403
```

**Cambio en caliente:** dar acceso al rol `admin`.

```bash
cd $ENVOY_OPA
probe() {  # $1 = rol → imprime el HTTP status desde client-app hacia server-app
  TOKEN=$(make -s token-raw ROLE=$1)
  kubectl --context kind-opa-cluster exec -n opa-ms -c client-app deploy/client-app -- \
    python -c "import urllib.request as u,urllib.error as e,ssl;r=u.Request('https://server-app.opa-ms.svc.cluster.local:8443/api/server/v1',headers={'Authorization':'Bearer $TOKEN'})
try: print(u.urlopen(r,context=ssl._create_unverified_context()).status)
except e.HTTPError as x: print(x.code)"
}
probe admin                               # 403

cd $DELIVERY
make policy-change ARGS='add-endpoint --caller admin --path /api/server/v1 --methods GET'
make test && make deploy-opa              # local; en CI: DELIVERY_MODE=pipeline
kubectl -n opa rollout history deploy/opa

cd $ENVOY_OPA && probe admin              # 200
make logs-opa                             # decision log con "result": true

# Rollback
cd $DELIVERY && git checkout -- policies/authz/data.json && make deploy-opa
cd $ENVOY_OPA && probe admin              # 403
make test-auth                            # 4/4
```

---

## 5. Modo GitOps en KinD (Flux)

Flux lee el **repo delivery** desde GitHub (`slashsre/opa-delivery-k8s`). Haz push de la rama
antes de instalar. Si el repo es privado, crea el secret y descomenta `pullSecret` en
`deploy/flux/flux-instance.yaml`:
`flux create secret git git-credentials -n flux-system --url=<url> --username=<user> --password=<token>`

```bash
cd $DELIVERY
git remote add origin https://github.com/slashsre/opa-delivery-k8s.git   # solo la primera vez
git push -u origin main feature/delivery-integration

cd $ENVOY_OPA
make delete-opa 2>/dev/null || true
make cluster-up images deploy-apps                  # sin OPA

cd $DELIVERY
make gitops-install GITOPS_REF=refs/heads/feature/delivery-integration   # GITOPS_URL = remote.origin.url
make gitops-status        # GitRepository flux-system y Kustomizations flux-system/opa: Ready
kubectl -n opa get deploy,cm -L kustomize.toolkit.fluxcd.io/name

cd $ENVOY_OPA && make test-auth                     # 4/4
```

**Cambio vía PR:**

```bash
cd $DELIVERY
make policy-change ARGS='add-endpoint --caller admin --path /api/server/v1 --methods GET'
make policy-publish DELIVERY_MODE=gitops BASE_BRANCH=feature/delivery-integration
#   → rama opa-delivery/<timestamp> + PR (con gh + GH_TOKEN; si no, abrirlo a mano)
# Mergear el PR, luego:
make gitops-reconcile     # o esperar el interval (1m)
make gitops-status        # opa: Applied revision feature/delivery-integration@sha1:<nuevo>
cd $ENVOY_OPA && probe admin                        # 200
```

**Drift (self-healing):**

```bash
kubectl -n opa scale deploy/opa --replicas=0
cd $DELIVERY && make gitops-reconcile
kubectl -n opa get deploy/opa                       # vuelve a 1/1
```

**Rollback GitOps:** `git revert <merge>` + push → `make gitops-reconcile` → `probe admin` = 403.

**Limpieza:** `cd $DELIVERY && make gitops-uninstall delete-opa`, y luego
`cd $ENVOY_OPA && make dist-clean`.

---

## 6. CI consumidor: Jenkins / GitHub Actions

Los pipelines viven en envoy-opa y hacen checkout de este repo.

### Jenkins (`envoy-opa-integration/8.-opa-delivery/Jenkinsfile`)

Setup: job Pipeline from SCM sobre envoy-opa, con Script Path `8.-opa-delivery/Jenkinsfile`.
Parámetro `DELIVERY_REPO_URL` y credenciales `opa-delivery-git` (push sobre el repo delivery) y
`opa-delivery-kubeconfig`. Requiere el plugin *build user vars*.

| # | Parámetros | Esperado |
|---|-----------|----------|
| J1 | `OPERATION=validate-only` | Checkout delivery + Tests + Render; sin commit |
| J2 | `add-endpoint`, `CALLER=admin`, `ENDPOINT_PATH=/api/server/v1`, `METHODS=GET`, `DELIVERY_MODE=gitops` | Rama `opa-delivery/envoy-opa-jenkins-<n>` + PR en el repo delivery |
| J3 | Repetir J2 | "Sin cambios": no hay commit |
| J4 | `remove-endpoint` …, `DELIVERY_MODE=pipeline` | Commit en `BASE_BRANCH` del delivery + `make deploy-opa` |
| J5 | `add-endpoint` con `METHODS=FOO` | Falla en *Apply change* |
| J6 | `remove-endpoint`, `CALLER=guest`, `ENDPOINT_PATH=/api/server/v1` | Falla en *Tests* y no publica |
| J7 | `apply-spec` con `examples/changes/example.json` | 3 cambios en un solo PR |

### GitHub Actions (`envoy-opa-integration/.github/workflows/opa-delivery.yml`)

Setup en envoy-opa: variable `OPA_DELIVERY_REPOSITORY` (default `slashsre/opa-delivery-k8s`), secret
`OPA_DELIVERY_TOKEN` (contents + pull-requests write sobre el repo delivery) y `KUBECONFIG_B64`
(modo pipeline).

| # | *Run workflow* | Esperado |
|---|----------------|----------|
| G1 | `operation=validate-only` | Tests + artifact `dist/`; sin publicar |
| G2 | `add-endpoint` …, `delivery_mode=gitops` | PR en el repo delivery (`opa-delivery/envoy-opa-integration-<run_id>`) |
| G3 | `delivery_mode=pipeline` | Push a `base_branch` del delivery + deploy |
| G4 | Cambio inválido o que rompe `guest` | Falla en *Tests* |

En el repo delivery, `.github/workflows/policy-check.yml` valida cada PR antes del merge
(`make test policy-render policy-bundle`).

---

## Referencia rápida de comandos (repo delivery)

```bash
make help
make test                                   # CLI + esquema + fmt + opa test
make policy-list
make policy-change ARGS='<operación> [flags]'
make policy-render | make policy-bundle
make policy-publish DELIVERY_MODE=gitops|pipeline [BASE_BRANCH=main]
make deploy-opa | make delete-opa | make logs-opa
make gitops-install [GITOPS_URL=...] [GITOPS_REF=refs/heads/<rama>]
make gitops-status | make gitops-reconcile | make gitops-uninstall
```

En envoy-opa: `make cluster-up images deploy-apps`, `make test-auth`,
`make token ROLE=<rol>` y `make dist-clean`.
