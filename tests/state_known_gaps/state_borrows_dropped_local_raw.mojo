# Must build: scripts/check.sh builds it, which shows only that the compiler
# accepts it. scripts/run_origin_gaps.sh runs it under AddressSanitizer and
# requires the report below, which shows that the request reads freed memory.
# Expected report: AddressSanitizer: heap-use-after-free
#
# Issue #122 through a raw handler: the twin of `state_borrows_dropped_local.mojo`
# (read its header), whose `main` asserts the same 200 and body "42" a request
# must give once the borrow is kept alive.

from std.memory import OwnedPointer
from std.testing import assert_equal

from muntin import App, Request, Response, State
from muntin.testing import TestClient


struct View[o: Origin[mut=False]](Movable):
    var p: Pointer[Int, Self.o]

    def __init__(out self, ref[Self.o] x: Int):
        self.p = Pointer(to=x)


def show[o: Origin[mut=False]](view: State[View[o]], req: Request) -> Response:
    return Response(200, String(view[].p[]))


@no_inline
def build(mut app: App):
    var token = OwnedPointer(42)
    app.get["/"](show[origin_of(token[])], State(View(token[])))


def main() raises:
    var app = App()
    build(app)
    var client = TestClient(app)
    var response = client.get("/")
    assert_equal(response.status, 200)
    assert_equal(response.text(), "42")
