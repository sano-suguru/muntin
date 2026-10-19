# Must build: scripts/check.sh builds it, which shows only that the compiler
# accepts it. scripts/run_origin_gaps.sh runs it under AddressSanitizer and
# requires the report below, which shows that the request reads freed memory.
# Expected report: AddressSanitizer: heap-use-after-free
#
# Evidence for docs/history/deferrals.md, "Closing `State`'s `AnyOrigin` hole"
# (pull request #175): the pointer of
# tests/state_known_gaps/state_any_origin_associated_type.mojo registers just
# as well inside a `List`, an owning container reached through a pointer whose
# untracked origin prints `{}` like `AnyOrigin`. So a check that walked a
# state's field types by reflection would miss it here even if it could read a
# pointer's origin. `main` asserts what a request must give once the borrow is
# kept alive (200, "42").
#
# If this file stops building, or stops reporting with its assertions passing,
# re-read that entry's revisit condition.

from std.memory import OwnedPointer
from std.testing import assert_equal

from muntin import App, State
from muntin.testing import TestClient


trait HasPtr:
    comptime Ptr: ImplicitlyCopyable & Deinitable


struct Marker(HasPtr):
    comptime Ptr = Pointer[Int, ImmutAnyOrigin]


struct H[T: HasPtr](Copyable, Movable):
    var p: Self.T.Ptr

    def __init__(out self, p: Self.T.Ptr):
        self.p = p


def show(h: State[List[H[Marker]]]) -> String:
    return String(h[][0].p[])


@no_inline
def build(mut app: App):
    var token = OwnedPointer(42)
    var items = List[H[Marker]]()
    items.append(H[Marker](Pointer[Int, ImmutAnyOrigin](to=token[])))
    app.get["/"](show, State(items^))


def main() raises:
    var app = App()
    build(app)
    var client = TestClient(app)
    var response = client.get("/")
    assert_equal(response.status, 200)
    assert_equal(response.text(), "42")
