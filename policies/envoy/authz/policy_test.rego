# -------------------------------------------------------------------
# Tests de la política genérica (make policy-test).
#
# - test_data_*: validan la data real de policies/authz/data.json
#   (se rompen si alguien quita un acceso que se espera).
# - test_engine_*: validan el motor con una data fija, independiente
#   de lo que contenga data.json.
# -------------------------------------------------------------------
package envoy.authz

# base64url("secret"), clave HS256 usada por envoy-opa-integration/1.-core/jwt-token.py
hs256_key = {"kty": "oct", "k": "c2VjcmV0"}

jwt(role) = t {
	t := io.jwt.encode_sign({"typ": "JWT", "alg": "HS256"}, {"sub": "tester", "role": role}, hs256_key)
}

req(method, path, auth) = {"attributes": {"request": {"http": {
	"method": method,
	"path": path,
	"headers": {"authorization": auth},
}}}}

req_no_auth(method, path) = {"attributes": {"request": {"http": {
	"method": method,
	"path": path,
	"headers": {},
}}}}

bearer(role) = b {
	b := concat(" ", ["Bearer", jwt(role)])
}

# ---------------------------------------------------------------
# Data real (equivalente a envoy-opa-integration/1.-core/test-auth.py)
# ---------------------------------------------------------------

test_data_health_is_public {
	allow with input as req_no_auth("GET", "/health")
}

test_data_root_is_public {
	allow with input as req_no_auth("GET", "/")
}

test_data_server_without_token_denied {
	not allow with input as req_no_auth("GET", "/api/server/v1")
}

test_data_server_guest_allowed {
	allow with input as req("GET", "/api/server/v1", bearer("guest"))
}

test_data_client_guest_post_with_query_allowed {
	allow with input as req("POST", "/api/client/v1?target=https://server-app", bearer("guest"))
}

test_data_server_unknown_role_denied {
	not allow with input as req("GET", "/api/server/v1", bearer("intruder"))
}

# ---------------------------------------------------------------
# Motor genérico con data fija
# ---------------------------------------------------------------

fixture = {
	"caller_claim": "role",
	"public_paths": ["/health*"],
	"callers": {"reader": {"endpoints": [
		{"path": "/api/items/*", "methods": ["GET"]},
		{"path": "/api/orders", "methods": ["GET", "POST"]},
	]}},
}

test_engine_glob_endpoint_allowed {
	allow with input as req("GET", "/api/items/42", bearer("reader")) with data.authz as fixture
}

test_engine_glob_does_not_cross_segments {
	not allow with input as req("GET", "/api/items/42/details", bearer("reader")) with data.authz as fixture
}

test_engine_method_not_allowed {
	not allow with input as req("DELETE", "/api/orders", bearer("reader")) with data.authz as fixture
}

test_engine_unknown_caller_denied {
	not allow with input as req("GET", "/api/orders", bearer("guest")) with data.authz as fixture
}

# Firmado con otra clave ("otro")
bearer_bad_signature = b {
	t := io.jwt.encode_sign({"typ": "JWT", "alg": "HS256"}, {"role": "reader"}, {"kty": "oct", "k": "b3Rybw"})
	b := concat(" ", ["Bearer", t])
}

test_engine_invalid_signature_denied {
	not allow with input as req("GET", "/api/orders", bearer_bad_signature) with data.authz as fixture
}

test_engine_non_bearer_scheme_denied {
	not allow with input as req("GET", "/api/orders", concat(" ", ["Basic", jwt("reader")])) with data.authz as fixture
}

test_engine_public_glob {
	allow with input as req_no_auth("GET", "/healthz") with data.authz as fixture
}

test_engine_custom_caller_claim {
	custom := {"caller_claim": "sub", "public_paths": [], "callers": {"tester": {"endpoints": [{"path": "/x", "methods": ["GET"]}]}}}
	allow with input as req("GET", "/x", bearer("whatever")) with data.authz as custom
}
