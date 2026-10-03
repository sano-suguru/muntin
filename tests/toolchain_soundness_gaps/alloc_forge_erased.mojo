# Mojo 1.1.0 toolchain-wide soundness gap: must build, never run
# (scripts/check.sh). It breaks the property M3-004 guarantees, one State
# alias replacing, mutating or destroying the payload another alias
# observes, but through a primitive that breaks the same property for
# standard-library types and existing Muntin storage, so it is outside the
# guarantee (docs/ARCHITECTURE.md, "State storage decision (M3-004)").
# If this stops building, the toolchain improved: reevaluate whether the
# sealed box and its unsafe boundary can be simplified.
#
# Primitive: forged allocation, against production `_Erased` on main: a
# route dispatches through an uninitialized header.
from std.memory.alloc import Layout, alloc
from muntin import App, Request
from muntin._handler_storage import _Erased, _Header


def hello() -> String:
    return "hi"


def main() raises:
    var app = App()
    app.get["/hello"](hello)
    var fake = alloc(Layout[_Header].single()).into_thin()
    swap(app._routes[0].handler._header, fake)
    var sink: _Erased
    sink._header = fake^
    print(app.handle(Request("GET", "/hello")).body)
