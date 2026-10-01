# Must not compile: application code outside Muntin replacing a stored
# handler's drop function. `_Erased` has no such field; the box's functions
# live in its heap header, reachable only through an `unsafe_`-named call.
# Expected diagnostic (checked by scripts/check.sh): '_Erased' value has no attribute '_drop'

from muntin import App
from muntin._handler_storage import _drop_box


def hello() -> String:
    return "hello"


def main():
    var app = App()
    app.get["/hello"](hello)
    app._routes[0].handler._drop = _drop_box[Int]
