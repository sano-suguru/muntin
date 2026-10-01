# Must not compile: copying a handler box. `_Erased` is not `Copyable`, so
# two owners of one allocation (and a double free) cannot be written.
# Expected diagnostic (checked by scripts/check.sh): '_Erased' value has no attribute 'copy'

from muntin._handler_storage import _Erased
from muntin.app import _call_none


def hello() -> String:
    return "hello"


def main() raises:
    var a = _Erased.__init__[call=_call_none](hello)
    var b = a.copy()
    _ = a.invoke([])
    _ = b.invoke([])
