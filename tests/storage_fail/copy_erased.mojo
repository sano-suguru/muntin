# Must not compile: copying a handler box. `_Erased` is move-only, so two
# owners of one allocation (and a double free) cannot be written.
# Expected diagnostic (checked by scripts/check.sh): value of type '_Erased' cannot be implicitly copied, it does not conform to 'ImplicitlyCopyable'

from muntin._handler_storage import _Erased
from muntin.app import _call_none


def hello() -> String:
    return "hello"


def main() raises:
    var a = _Erased.__init__[call=_call_none](hello)
    var b = a
    _ = a.invoke([])
    _ = b.invoke([])
