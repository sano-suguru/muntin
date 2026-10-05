# Must not compile: a production handler box paired with the adapter for
# another handler shape (here the arity-1 adapter with an `Int` slot).
# `call` and the boxed value share the type parameter F of
# `_Erased.__init__`, so the mismatch is rejected when the box is made.
# Expected diagnostic (checked by scripts/check.sh): value passed to 'value' cannot be converted from 'def hello() thin -> String' to 'def(var Int) raises Never thin -> String'

from muntin._handler_storage import _Erased
from muntin.app import _call_1


def hello() -> String:
    return "hello"


def main():
    _ = _Erased.__init__[call=_call_1[Int, Never, String]](hello)
