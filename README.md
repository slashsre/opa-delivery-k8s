# OPA Delivery (pipeline externo o GitOps)

Repositorio de delivery de políticas OPA para Envoy `ext_authz`
([slashsre/opa-delivery-k8s](https://github.com/slashsre/opa-delivery-k8s)). Contiene **toda la lógica**:

- la política genérica y la data con los endpoints autorizados;
- el CLI para modificarlos;
- el despliegue de OPA en Kubernetes (Kustomize);
- la configuración de Flux para el modo GitOps.

Los proyectos consumidores (p. ej. `envoy-opa-integration`) solo tienen un Jenkinsfile o un
workflow que hace checkout de este repo y ejecuta sus scripts.

| Modo | Quién dispara | Quién despliega |
|------|---------------|-----------------|
| `pipeline` | Pipeline consumidor (Jenkins / GitHub Actions / GitLab) | El pipeline, con `kubectl apply -k deploy/opa` |
| `gitops`   | El pipeline consumidor abre un **PR en este repo** (o alguien edita y abre el PR) | **Flux**, que sincroniza este repo al mergear |

Los dos modos usan el mismo artefacto (`deploy/opa`) y las mismas pruebas (`make test`).

```
 envoy-opa-integration (u otro consumidor)
   Jenkinsfile / GitHub workflow ── checkout ──┐
                                                ▼
 opa-delivery-k8s (este repo)
   scripts/apply-change.sh   → tools/opa_delivery.py modifica policies/authz/data.json
   make test                 → tests del CLI + esquema + opa fmt + opa test (OPA 0.17.3)
   make policy-render        → deploy/opa (Kustomize) → ConfigMap opa-policies-<hash>
   scripts/publish-change.sh
        ├─ DELIVERY_MODE=pipeline → push a main + kubectl apply -k deploy/opa
        └─ DELIVERY_MODE=gitops   → rama + PR → merge → Flux aplica ./deploy/opa
                                                ▼
   OPA (namespace opa) monta el ConfigMap en /policies/authz → data.authz
   Nuevo hash = rollout automático. Envoy → opa.opa.svc.cluster.local:9191
```

## Estructura

```
.
├── policies/                       # Fuente de verdad de la autorización
│   ├── envoy/authz/policy.rego     # Política genérica (lee data.authz)
│   ├── envoy/authz/policy_test.rego
│   ├── authz/data.json             # Callers / endpoints / métodos / paths públicos
│   └── kustomization.yaml          # ConfigMap opa-policies-<hash>
├── tools/
│   ├── opa_delivery.py             # CLI (Python 3, sin dependencias)
│   └── test_opa_delivery.py        # Tests del CLI
├── scripts/
│   ├── apply-change.sh             # Variables de entorno del CI → CLI
│   └── publish-change.sh           # gitops (PR) | pipeline (push + kubectl)
├── deploy/
│   ├── opa/                        # Kustomize de OPA (Deployment, Services, config)
│   └── flux/                       # FluxInstance + Kustomization "opa"
├── examples/changes/example.json   # Spec de cambios en lote
├── .github/workflows/policy-check.yml  # Gate de PRs de este repo
├── Makefile
├── TESTING.md                      # Comandos y set de pruebas
└── version
```

## Modelo de datos (`data.authz`)

```json
{
  "caller_claim": "role",
  "public_paths": ["/", "/health", "/healthz"],
  "callers": {
    "guest": {
      "description": "Rol por defecto del POC",
      "endpoints": [
        { "path": "/api/server/v1", "methods": ["GET", "POST"] },
        { "path": "/api/items/*",   "methods": ["GET"] }
      ]
    }
  }
}
```

- **caller**: valor del claim `caller_claim` del JWT verificado. En el POC es `role`; se puede
  cambiar a `sub`, `azp`, etc. con `set-caller-claim`. La identidad sale del token firmado y no
  de un header, que el cliente podría falsificar.
- **path**: exacto o glob con `/` como delimitador. `/api/items/*` no cruza segmentos. El query
  string se ignora.
- **public_paths**: no requieren JWT.

## Uso local

```bash
make help
make policy-list
make policy-change ARGS='add-endpoint --caller guest --path /api/server/v2 --methods GET,POST'
make policy-change ARGS='remove-endpoint --caller guest --path /api/server/v2 --methods POST'
make policy-change ARGS='add-caller --caller admin --description "Administradores"'
make policy-change ARGS='apply --spec examples/changes/example.json'
make test                                       # CLI + esquema + fmt + opa test
make policy-publish DELIVERY_MODE=gitops        # rama + PR
make policy-publish DELIVERY_MODE=pipeline      # push a main + make deploy-opa
```

## Contrato para pipelines consumidores

Cualquier CI hace checkout de este repo y ejecuta:

```bash
# Variables: OPERATION, CALLER, ENDPOINT_PATH, METHODS, DESCRIPTION, CHANGE_SPEC_FILE
scripts/apply-change.sh
make test policy-render policy-bundle
# Variables: DELIVERY_MODE, BASE_BRANCH, CHANGE_BRANCH, COMMIT_MESSAGE, CHANGE_AUTHOR,
#            GH_TOKEN (PR automático), SKIP_DEPLOY
scripts/publish-change.sh
```

`OPERATION` admite: `validate-only`, `add-endpoint`, `remove-endpoint`, `add-caller`,
`remove-caller`, `add-public-path`, `remove-public-path` y `apply-spec`.

Ejemplos listos en `envoy-opa-integration`: `8.-opa-delivery/Jenkinsfile` y
`.github/workflows/opa-delivery.yml`. Cada pipeline necesita credenciales con push sobre
**este** repo y, en modo pipeline, un kubeconfig del cluster.

## Modo GitOps (Flux)

```bash
make gitops-install                       # rama main (GITOPS_URL = remote origin)
make gitops-install GITOPS_REF=refs/heads/feature/delivery-integration
make gitops-status
make gitops-reconcile
```

- [`deploy/flux/flux-instance.yaml`](deploy/flux/flux-instance.yaml): Flux Operator con la
  `FluxInstance` que sincroniza este repo, en el path `./deploy/flux/clusters/kind`. Si el repo
  es privado, usa `pullSecret`.
- [`deploy/flux/clusters/kind/opa.yaml`](deploy/flux/clusters/kind/opa.yaml): Kustomization
  `opa` que aplica `./deploy/opa`, con `prune` y `wait`.
- Para otro cluster o entorno, agrega `deploy/flux/clusters/<entorno>/` y apunta la FluxInstance
  de ese cluster a ese path.

> No mezcles los modos en el mismo cluster. Si Flux gestiona `deploy/opa`, un `kubectl apply`
> se revierte en la siguiente reconciliación.

## Apertura a bundles remotos (Artifactory / ACR)

Hoy la política y la data van en un ConfigMap: tiene un límite de 1 MiB y cada cambio reinicia
OPA. Para pasar a bundles:

1. `make policy-bundle` ya genera `dist/opa-bundle.tar.gz` (verificado con `opa run -b` en 0.17.3).
2. Publícalo desde el pipeline, en la etapa *Render & bundle*.
3. Activa `services` y `bundles` en [`deploy/opa/opa-config.yaml`](deploy/opa/opa-config.yaml)
   (hay ejemplos comentados) y quita el volumen `opa-policies` del Deployment.
   - Artifactory (HTTP genérico) funciona con OPA 0.17.
   - ACR (OCI) requiere OPA ≥ 0.40 y Envoy con la API v3 de `ext_authz`.

## Pendientes conocidos

- El secreto del JWT (`"secret"`) está en `policy.rego`. Hay que moverlo a JWKS o a un Secret
  antes de usar esto fuera del POC.
- La API REST de OPA (:8181) no tiene autenticación.
- OPA 0.17.3 y Envoy 1.13 (API v2) son versiones antiguas. Subirlas implica migrar el Rego a la
  sintaxis v1.
