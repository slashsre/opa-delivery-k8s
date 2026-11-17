# -------------------------------------------------------------------
# Política genérica de autorización para Envoy ext_authz.
#
# La política NO contiene endpoints ni roles: todo se lee desde
# data.authz (policies/authz/data.json), que se modifica con
# el delivery (tools/opa_delivery.py) y se despliega vía
# pipeline externo o GitOps (Flux).
#
# Sintaxis Rego v0: compatible con la imagen openpolicyagent/opa:0.17.3-istio.
# -------------------------------------------------------------------
package envoy.authz

import input.attributes.request.http as http_request

default allow = false

# Configuración gestionada por el delivery.
config = data.authz

# TODO: mover el secreto a una fuente segura (JWKS / Secret) antes de producción.
jwt_secret = "secret"

# Path sin query string: /api/client/v1?target=... -> /api/client/v1
request_path = p {
	p := split(http_request.path, "?")[0]
}

token = {"valid": valid, "payload": payload} {
	[scheme, encoded] := split(http_request.headers.authorization, " ")
	lower(scheme) == "bearer"
	[valid, _, payload] := io.jwt.decode_verify(encoded, {"secret": jwt_secret})
}

# Identidad del caller: valor del claim configurado (por defecto "role").
caller = c {
	token.valid
	c := token.payload[config.caller_claim]
}

# Rutas públicas (sin JWT): health checks, raíz, etc.
allow {
	some i
	glob.match(config.public_paths[i], ["/"], request_path)
}

# Rutas protegidas: el caller debe tener el endpoint y el método autorizados.
allow {
	endpoint := config.callers[caller].endpoints[_]
	glob.match(endpoint.path, ["/"], request_path)
	endpoint.methods[_] == http_request.method
}
