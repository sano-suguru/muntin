"""M3-091 evidence: checks the spike's document against the exchanges it sent.

Run the spike with MUNTIN_OPENAPI_OUT=<dir>, then, with openapi-spec-validator
and jsonschema installed (not standard library; not run by CI):

    python3 prototype-m3-091/validate_openapi.py <dir>

1. The document is a valid OpenAPI 3.1 document (openapi-spec-validator).
2. A differential check of every exchange: the document admits the request
   (its path, parameters with `allowEmptyValue`, and request body: presence,
   media type and schema) exactly when Muntin did not refuse it (400, 413,
   415); a 2xx answer, or one of a status the document names (an
   application's addition), meets the response the document gives for it,
   and no other answer meets a described one with content.
3. The known gaps the record states must still show, each as the mismatch
   named below; any other mismatch fails the run.
"""

import json
import re
import sys
import urllib.parse

from jsonschema import Draft202012Validator
from openapi_spec_validator import validate

REFUSALS = {400, 413, 415}
# (method, target, body) -> the mismatch the record accepts.
KNOWN_GAPS = {
    ("POST", "/counts", '{"n":1.0}'): "admitted, refused",  # integer takes 1.0
    ("POST", "/versions", "3.0"): "admitted, refused",  # hand-written: {}
}


def operation(doc, method, path):
    for template, item in doc["paths"].items():
        names = []

        def group(m):
            names.append(m.group(1))
            return "([^/]+)"

        pattern = "^" + re.sub(r"\\\{([^}]*)\\\}", group, re.escape(template)) + "$"
        m = re.match(pattern, path)
        if m and method.lower() in item:
            values = {n: urllib.parse.unquote(v) for n, v in zip(names, m.groups())}
            return item[method.lower()], values
    return None, None


def value_for(schema, text):
    if schema.get("type") == "integer" and re.fullmatch(r"-?[0-9]+", text):
        return int(text)
    return text


def admits(op, path_values, query, ex):
    """Whether the document admits the request, and why not."""
    pairs = urllib.parse.parse_qsl(query, keep_blank_values=True)
    q = dict(pairs)
    for p in op.get("parameters", []):
        name, schema = p["name"], p["schema"]
        if p["in"] == "path":
            text = path_values[name]
        elif name in q:
            text = q[name]
            if text == "" and p.get("allowEmptyValue"):
                continue
        elif p["required"]:
            return False, "missing " + name
        else:
            continue
        if not Draft202012Validator(schema).is_valid(value_for(schema, text)):
            return False, "parameter " + name
    rb = op.get("requestBody")
    if rb is not None:
        if ex["body"] == "":
            return (False, "empty body") if rb["required"] else (True, "")
        content = rb["content"]
        if "application/json" in content:
            if not ex["json"]:
                return False, "media type"
            try:
                value = json.loads(ex["body"])
            except ValueError:
                return False, "not JSON"
            schema = content["application/json"]["schema"]
            if not Draft202012Validator(schema).is_valid(value):
                return False, "body schema"
    return True, ""


def response_for(op, status):
    rs = op["responses"]
    return rs.get(str(status)) or rs.get(f"{status // 100}XX") or rs.get("default")


def check(ex, op, values):
    """The mismatch an exchange shows, or None."""
    path, _, query = ex["target"].partition("?")
    ok, why = admits(op, values, query, ex)
    refused = ex["status"] in REFUSALS
    if ok and refused:
        return "admitted, refused"
    if not ok and not refused:
        return f"refused by the document ({why}), admitted"
    entry = response_for(op, ex["status"])
    explicit = str(ex["status"]) in op["responses"]
    if ex["status"] // 100 == 2 or explicit:
        if ex["status"] in (204, 205) and entry and "content" in entry:
            return "content described for " + str(ex["status"])
        if entry and "application/json" in entry.get("content", {}):
            if ex["content_type"] != "application/json":
                return "not JSON"
            schema = entry["content"]["application/json"]["schema"]
            if not Draft202012Validator(schema).is_valid(json.loads(ex["response"])):
                return "response schema"
    elif entry is not None and "content" in entry:
        return "a non-2xx answer described with content"
    return None


def main():
    d = sys.argv[1]
    doc = json.load(open(d + "/openapi.json"))
    validate(doc)
    ops = sum(len(v) for v in doc["paths"].values())
    print(f"openapi-spec-validator: a valid OpenAPI 3.1 document, {ops} operations")
    agree = gaps = 0
    failures = []
    exchanges = [json.loads(line) for line in open(d + "/exchanges.jsonl")]
    for ex in exchanges:
        op, values = operation(doc, ex["method"], ex["target"].partition("?")[0])
        key = (ex["method"], ex["target"], ex["body"])
        got = "no operation" if op is None else check(ex, op, values)
        want = KNOWN_GAPS.get(key)
        if got == want and want is not None:
            gaps += 1
        elif got is None and want is None:
            agree += 1
        else:
            failures.append(f"{key}: {got} (expected {want})")
    print(
        f"{len(exchanges)} exchanges: {agree} agree with the document, "
        f"{gaps} show their known gap, {len(failures)} mismatch"
    )
    for f in failures:
        print("MISMATCH", f)
    sys.exit(1 if failures or gaps != len(KNOWN_GAPS) else 0)


main()
