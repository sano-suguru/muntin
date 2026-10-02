# Must not compile: catching the error of a handler whose inferred error
# type is bounded only by AnyType (M2-010). The caught value must be
# destroyable, so the adapter's error parameter is `E: Deinitable`; `Never`
# (non-raising handler) and `Error` satisfy it.
# Expected diagnostic (checked by scripts/check.sh): 'e' abandoned without being explicitly destroyed

from muntin import Response


def call[E: AnyType, //](handler: def() thin raises E -> String) -> Response:
    try:
        return Response.text(handler())
    except e:
        return Response.text("Internal Server Error", status=500)


def hello() -> String:
    return "hello"


def main():
    _ = call(hello)
