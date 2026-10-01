# Must not compile: an erased handler paired with a trampoline built for
# another handler type. `call` and the boxed value share the type parameter F
# of `_Erased.__init__`, so a mismatch is rejected when the box is made.
# Expected diagnostic (checked by scripts/check.sh): cannot be converted from 'def get_id(id: Int) thin -> String' to 'def(String) raises thin -> String'

from handler_storage_spike import _Erased, _call1s


def get_id(id: Int) -> String:
    return String(id)


def main():
    _ = _Erased.__init__[call=_call1s[String]](get_id)
