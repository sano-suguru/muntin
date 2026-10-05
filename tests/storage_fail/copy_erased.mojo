# Must not compile: copying a handler box. `_Erased` is not `Copyable`, so
# two owners of one allocation (and a double free) cannot be written.
# Expected diagnostic (checked by scripts/check.sh): '_Erased' value has no attribute 'copy'

from muntin import Response
from muntin._handler_storage import _Erased


def hello() -> String:
    return "hello"


def _hello_trampoline(
    handler: def() thin -> String, args: List[String]
) -> Response:
    """A local adapter for `hello`'s shape: the fixture needs a box, not
    production's adapters."""
    return Response.text(handler())


def main() raises:
    var a = _Erased.__init__[call=_hello_trampoline](hello)
    var b = a.copy()
    _ = a.invoke([])
    _ = b.invoke([])
