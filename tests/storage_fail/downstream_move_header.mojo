# Must not compile: code outside Muntin moving one handler box's handle over
# another's. The overwritten `ThinAllocation` would be dropped without being
# freed, and it must be destroyed explicitly. (Through `app._routes[i]` the
# move is rejected even earlier: a list element cannot be moved out of.)
# Expected diagnostic (checked by scripts/check.sh): 'a' abandoned without being explicitly destroyed: A `ThinAllocation` owns heap storage

from muntin._handler_storage import _Erased
from muntin.app import _call_none


def hello() -> String:
    return "hello"


def main():
    var a = _Erased.__init__[call=_call_none](hello)
    var b = _Erased.__init__[call=_call_none](hello)
    a._header = b._header^
