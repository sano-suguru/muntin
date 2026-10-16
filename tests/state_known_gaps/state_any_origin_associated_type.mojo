# Must build: scripts/check.sh builds it, which shows only that the compiler
# accepts it. scripts/run_origin_gaps.sh runs it under AddressSanitizer and
# requires the report below, which shows that the request reads freed memory.
# Expected report: AddressSanitizer: heap-use-after-free
#
# Found by the review of docs/history/architecture-decisions.md, "State
# borrowing decision (M3-074)": `State` refuses a type whose reflected name
# shows an origin, but a field typed through a trait's associated type
# (`Self.T.Ptr`) may be `Pointer[Int, ImmutAnyOrigin]` although a field
# written as that type is refused ("struct fields cannot expose AnyOrigin",
# tests/context_fail/any_origin_field.mojo), and the name `H[Marker]` shows no
# origin. A pointer to a local built with `ImmutAnyOrigin` then outlives it, in
# safe code that names no `_` member. It is the toolchain-wide `AnyOrigin`
# hole of tests/registration_known_gaps/safe_dangling_any_origin_slice.mojo,
# which issue #122 left out, reaching `State`; a local's own origin cannot be
# hidden this way (a module-level declaration cannot name it). `main` asserts
# what a request must give once the borrow is kept alive (200, "42").
#
# If this file stops building, or stops reporting with its assertions passing,
# re-read M3-074's soundness argument and its revisit conditions.

from std.memory import OwnedPointer
from std.testing import assert_equal

from muntin import App, State
from muntin.testing import TestClient


trait HasPtr:
    comptime Ptr: ImplicitlyCopyable & Deinitable


struct Marker(HasPtr):
    comptime Ptr = Pointer[Int, ImmutAnyOrigin]


struct H[T: HasPtr](Movable):
    var p: Self.T.Ptr

    def __init__(out self, p: Self.T.Ptr):
        self.p = p


def show(h: State[H[Marker]]) -> String:
    return String(h[].p[])


@no_inline
def build(mut app: App):
    var token = OwnedPointer(42)
    app.get["/"](
        show, State(H[Marker](Pointer[Int, ImmutAnyOrigin](to=token[])))
    )


def main() raises:
    var app = App()
    build(app)
    var client = TestClient(app)
    var response = client.get("/")
    assert_equal(response.status, 200)
    assert_equal(response.text(), "42")
