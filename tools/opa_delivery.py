#!/usr/bin/env python3
"""
opa_delivery — gestiona la data de autorización de OPA (data.authz).

Características:
  * Python 3, solo librería estándar (corre en cualquier agente CI).
  * Operaciones idempotentes: aplicar dos veces el mismo cambio no hace nada.
  * Salida determinística (orden estable) -> diffs limpios en Git / PRs.
  * Valida el esquema antes de escribir.

Ejemplos:
  opa_delivery.py list
  opa_delivery.py add-endpoint    --caller guest --path /api/server/v2 --methods GET,POST
  opa_delivery.py remove-endpoint --caller guest --path /api/server/v2 --methods POST
  opa_delivery.py remove-endpoint --caller guest --path /api/server/v2
  opa_delivery.py add-caller      --caller admin --description "Administradores"
  opa_delivery.py remove-caller   --caller admin
  opa_delivery.py add-public-path    --path "/metrics"
  opa_delivery.py remove-public-path --path "/metrics"
  opa_delivery.py apply --spec examples/changes/example.json
  opa_delivery.py validate
"""

import argparse
import json
import os
import re
import sys

ROOT_DIR = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
DEFAULT_DATA = os.path.join(ROOT_DIR, "policies", "authz", "data.json")

HTTP_METHODS = ("GET", "POST", "PUT", "PATCH", "DELETE", "HEAD", "OPTIONS")
CALLER_RE = re.compile(r"^[A-Za-z0-9._:@-]{1,128}$")
PATH_RE = re.compile(r"^/[A-Za-z0-9._~!$&'()*+,;=:@%/{}-]*$")


class DeliveryError(Exception):
    pass


# ---------------------------------------------------------------------------
# Carga / guardado
# ---------------------------------------------------------------------------
def load(path):
    if not os.path.exists(path):
        return {"caller_claim": "role", "public_paths": [], "callers": {}}
    with open(path, "r", encoding="utf-8") as fh:
        return json.load(fh)


def normalize(data):
    """Orden estable para que el JSON resultante produzca diffs mínimos."""
    data["public_paths"] = sorted(set(data.get("public_paths", [])))
    callers = data.get("callers", {})
    for caller in callers.values():
        eps = caller.get("endpoints", [])
        for ep in eps:
            ep["methods"] = sorted(set(m.upper() for m in ep.get("methods", [])))
        caller["endpoints"] = sorted(eps, key=lambda e: e["path"])
    data["callers"] = callers
    return data


def save(path, data):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump(data, fh, indent=2, sort_keys=True, ensure_ascii=False)
        fh.write("\n")
    os.replace(tmp, path)


# ---------------------------------------------------------------------------
# Validación de esquema
# ---------------------------------------------------------------------------
def validate(data):
    errors = []
    if not isinstance(data, dict):
        return ["la raíz debe ser un objeto JSON"]

    claim = data.get("caller_claim")
    if not isinstance(claim, str) or not claim:
        errors.append("caller_claim debe ser un string no vacío (ej. 'role', 'sub')")

    public = data.get("public_paths")
    if not isinstance(public, list):
        errors.append("public_paths debe ser una lista")
    else:
        for p in public:
            if not isinstance(p, str) or not PATH_RE.match(p):
                errors.append("public_paths: path inválido %r" % (p,))

    callers = data.get("callers")
    if not isinstance(callers, dict):
        errors.append("callers debe ser un objeto {caller: {...}}")
        return errors

    for name, caller in callers.items():
        where = "callers.%s" % name
        if not CALLER_RE.match(name):
            errors.append("%s: nombre de caller inválido" % where)
        if not isinstance(caller, dict):
            errors.append("%s: debe ser un objeto" % where)
            continue
        unknown = set(caller) - {"description", "endpoints"}
        if unknown:
            errors.append("%s: campos desconocidos %s" % (where, sorted(unknown)))
        eps = caller.get("endpoints", [])
        if not isinstance(eps, list):
            errors.append("%s.endpoints debe ser una lista" % where)
            continue
        seen = set()
        for i, ep in enumerate(eps):
            ewhere = "%s.endpoints[%d]" % (where, i)
            if not isinstance(ep, dict):
                errors.append("%s: debe ser un objeto" % ewhere)
                continue
            path = ep.get("path")
            if not isinstance(path, str) or not PATH_RE.match(path):
                errors.append("%s.path inválido %r (debe empezar con '/')" % (ewhere, path))
            elif path in seen:
                errors.append("%s.path duplicado %r" % (ewhere, path))
            else:
                seen.add(path)
            methods = ep.get("methods")
            if not isinstance(methods, list) or not methods:
                errors.append("%s.methods debe ser una lista no vacía" % ewhere)
            else:
                bad = [m for m in methods if m not in HTTP_METHODS]
                if bad:
                    errors.append("%s.methods inválidos %s (permitidos: %s)"
                                  % (ewhere, bad, ",".join(HTTP_METHODS)))
            unknown = set(ep) - {"path", "methods"}
            if unknown:
                errors.append("%s: campos desconocidos %s" % (ewhere, sorted(unknown)))
    return errors


# ---------------------------------------------------------------------------
# Operaciones (todas idempotentes). Devuelven una lista de cambios aplicados.
# ---------------------------------------------------------------------------
def parse_methods(value):
    if value is None or value == "":
        return []
    if isinstance(value, list):
        items = value
    else:
        items = value.split(",")
    methods = [m.strip().upper() for m in items if m.strip()]
    bad = [m for m in methods if m not in HTTP_METHODS]
    if bad:
        raise DeliveryError("métodos inválidos %s (permitidos: %s)" % (bad, ",".join(HTTP_METHODS)))
    return methods


def require(value, name):
    if not value:
        raise DeliveryError("falta el parámetro '%s'" % name)
    return value


def check_caller(name):
    require(name, "caller")
    if not CALLER_RE.match(name):
        raise DeliveryError("caller inválido %r" % name)
    return name


def check_path(path):
    require(path, "path")
    if not PATH_RE.match(path):
        raise DeliveryError("path inválido %r (debe empezar con '/')" % path)
    return path


def op_add_caller(data, caller, description=None, **_):
    check_caller(caller)
    callers = data.setdefault("callers", {})
    if caller in callers:
        if description and callers[caller].get("description") != description:
            callers[caller]["description"] = description
            return ["caller %s: descripción actualizada" % caller]
        return []
    callers[caller] = {"endpoints": []}
    if description:
        callers[caller]["description"] = description
    return ["caller %s: creado" % caller]


def op_remove_caller(data, caller, **_):
    check_caller(caller)
    if data.get("callers", {}).pop(caller, None) is None:
        return []
    return ["caller %s: eliminado" % caller]


def op_add_endpoint(data, caller, path, methods, description=None, **_):
    check_path(path)
    methods = parse_methods(methods)
    if not methods:
        raise DeliveryError("add-endpoint requiere --methods")
    changes = op_add_caller(data, caller, description)
    eps = data["callers"][caller].setdefault("endpoints", [])
    ep = next((e for e in eps if e["path"] == path), None)
    if ep is None:
        eps.append({"path": path, "methods": sorted(set(methods))})
        return changes + ["caller %s: endpoint %s %s agregado" % (caller, ",".join(sorted(set(methods))), path)]
    new = sorted(set(methods) - set(ep["methods"]))
    if new:
        ep["methods"] = sorted(set(ep["methods"]) | set(new))
        changes.append("caller %s: endpoint %s +%s" % (caller, path, ",".join(new)))
    return changes


def op_remove_endpoint(data, caller, path, methods=None, **_):
    check_caller(caller)
    check_path(path)
    methods = parse_methods(methods)
    caller_obj = data.get("callers", {}).get(caller)
    if not caller_obj:
        return []
    eps = caller_obj.get("endpoints", [])
    ep = next((e for e in eps if e["path"] == path), None)
    if ep is None:
        return []
    if not methods:
        eps.remove(ep)
        return ["caller %s: endpoint %s eliminado" % (caller, path)]
    removed = sorted(set(ep["methods"]) & set(methods))
    if not removed:
        return []
    ep["methods"] = sorted(set(ep["methods"]) - set(removed))
    if not ep["methods"]:
        eps.remove(ep)
        return ["caller %s: endpoint %s eliminado (sin métodos)" % (caller, path)]
    return ["caller %s: endpoint %s -%s" % (caller, path, ",".join(removed))]


def op_add_public_path(data, path, **_):
    check_path(path)
    public = data.setdefault("public_paths", [])
    if path in public:
        return []
    public.append(path)
    return ["public path %s agregado" % path]


def op_remove_public_path(data, path, **_):
    check_path(path)
    public = data.setdefault("public_paths", [])
    if path not in public:
        return []
    public.remove(path)
    return ["public path %s eliminado" % path]


def op_set_caller_claim(data, claim, **_):
    require(claim, "claim")
    if data.get("caller_claim") == claim:
        return []
    data["caller_claim"] = claim
    return ["caller_claim = %s" % claim]


OPERATIONS = {
    "add-caller": op_add_caller,
    "remove-caller": op_remove_caller,
    "add-endpoint": op_add_endpoint,
    "remove-endpoint": op_remove_endpoint,
    "add-public-path": op_add_public_path,
    "remove-public-path": op_remove_public_path,
    "set-caller-claim": op_set_caller_claim,
}


def run_operation(data, op, params):
    fn = OPERATIONS.get(op)
    if fn is None:
        raise DeliveryError("operación desconocida %r (válidas: %s)" % (op, ", ".join(sorted(OPERATIONS))))
    params = dict(params)
    for key in ("caller", "path", "methods", "description", "claim"):
        params.setdefault(key, None)
    return fn(data, **params)


def load_spec(path):
    """
    Spec de cambios (JSON), útil para PRs / GitOps o para pipelines que
    reciben un archivo en lugar de parámetros sueltos:
      {"operations": [
        {"op": "add-endpoint", "caller": "guest", "path": "/api/x", "methods": ["GET"]},
        {"op": "remove-caller", "caller": "old-client"}
      ]}
    """
    with open(path, "r", encoding="utf-8") as fh:
        spec = json.load(fh)
    ops = spec.get("operations") if isinstance(spec, dict) else None
    if not isinstance(ops, list) or not ops:
        raise DeliveryError("el spec debe tener una lista 'operations' no vacía")
    return ops


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------
def cmd_list(data):
    print("caller_claim: %s" % data.get("caller_claim"))
    print("public_paths: %s" % (", ".join(data.get("public_paths", [])) or "-"))
    print("callers:")
    for name in sorted(data.get("callers", {})):
        caller = data["callers"][name]
        desc = caller.get("description")
        print("  - %s%s" % (name, "  (%s)" % desc if desc else ""))
        for ep in caller.get("endpoints", []):
            print("      %-8s %s" % (",".join(ep["methods"]), ep["path"]))


def build_parser():
    parser = argparse.ArgumentParser(description="Gestiona la data de autorización de OPA (data.authz)")
    parser.add_argument("--data", default=os.environ.get("OPA_DATA_FILE", DEFAULT_DATA),
                        help="ruta a data.json (default: %(default)s)")
    parser.add_argument("--dry-run", action="store_true", help="muestra los cambios sin escribir")
    sub = parser.add_subparsers(dest="command")
    sub.required = True

    sub.add_parser("list", help="lista callers y endpoints")
    sub.add_parser("validate", help="valida el esquema de data.json")

    p = sub.add_parser("apply", help="aplica un spec JSON con varias operaciones")
    p.add_argument("--spec", required=True)

    for name in OPERATIONS:
        p = sub.add_parser(name)
        if name in ("add-caller", "remove-caller", "add-endpoint", "remove-endpoint"):
            p.add_argument("--caller", required=True)
        if name in ("add-endpoint", "remove-endpoint", "add-public-path", "remove-public-path"):
            p.add_argument("--path", required=True)
        if name in ("add-endpoint", "remove-endpoint"):
            p.add_argument("--methods", help="lista separada por comas, ej. GET,POST")
        if name in ("add-caller", "add-endpoint"):
            p.add_argument("--description")
        if name == "set-caller-claim":
            p.add_argument("--claim", required=True)
    return parser


def main(argv=None):
    args = build_parser().parse_args(argv)
    data = load(args.data)

    try:
        if args.command == "list":
            cmd_list(data)
            return 0

        if args.command == "validate":
            errors = validate(data)
            if errors:
                for err in errors:
                    print("ERROR: %s" % err, file=sys.stderr)
                return 1
            print("OK: %s es válido" % os.path.relpath(args.data))
            return 0

        if args.command == "apply":
            operations = load_spec(args.spec)
        else:
            params = {k: v for k, v in vars(args).items()
                      if k in ("caller", "path", "methods", "description", "claim")}
            operations = [dict(params, op=args.command)]

        changes = []
        for operation in operations:
            operation = dict(operation)
            op = operation.pop("op", None)
            changes += run_operation(data, op, operation)
    except DeliveryError as exc:
        print("ERROR: %s" % exc, file=sys.stderr)
        return 2

    data = normalize(data)
    errors = validate(data)
    if errors:
        for err in errors:
            print("ERROR: %s" % err, file=sys.stderr)
        return 1

    if not changes:
        print("Sin cambios (la operación ya estaba aplicada).")
        return 0

    for change in changes:
        print("* %s" % change)
    if args.dry_run:
        print("(dry-run: no se escribió %s)" % os.path.relpath(args.data))
    else:
        save(args.data, data)
        print("Actualizado %s" % os.path.relpath(args.data))
    return 0


if __name__ == "__main__":
    sys.exit(main())
