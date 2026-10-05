# Must not compile: code outside Muntin moving one handler box's handle over
# another's. The overwritten `ThinAllocation` would be dropped without being
# freed, and it must be destroyed explicitly. (Through `app._routes[i]` the
# move is rejected even earlier: a list element cannot be moved out of.)
# Expected diagnostic (checked by scripts/check.sh): 'a' abandoned without being explicitly destroyed: A `ThinAllocation` owns heap storage

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


def main():
    var a = _Erased.__init__[call=_hello_trampoline](hello)
    var b = _Erased.__init__[call=_hello_trampoline](hello)
    a._header = b._header^
