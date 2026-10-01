# Must not compile: application code outside Muntin replacing a stored
# handler's drop function. `_Erased` has no such field; the box's functions
# live in its heap header, reachable only through `unsafe_ptr()` or the
# stdlib's private `ThinAllocation._ptr`.
# Expected diagnostic (checked by scripts/check.sh): '_Erased' value has no attribute '_drop'

from muntin import App
from muntin._handler_storage import _unsafe_drop_box


def hello() -> String:
    return "hello"


def main():
    var app = App()
    app.get["/hello"](hello)
    app._routes[0].handler._drop = _unsafe_drop_box[Int]
