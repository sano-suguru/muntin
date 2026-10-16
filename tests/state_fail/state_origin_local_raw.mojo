# Must not build: issue #122 through a stateful raw handler. A route erases
# its `State[S]` and the `App`'s type does not carry the origins in `S`, so before
# docs/history/architecture-decisions.md, "State borrowing decision (M3-074)",
# this registered and a request read `token` after `build` dropped it
# (AddressSanitizer: heap-use-after-free, pull request #118). `State` now
# refuses a type whose reflected name shows an origin. `main` still asserts
# what a request would have to answer if the borrow were kept alive (200,
# "42"), so the file keeps #122's acceptance case.
#
# If this file builds, the reflected name stopped showing the origin
# (`{}`) or the rule was removed: a borrowing state registers again.
# Expected diagnostic (checked by scripts/check.sh): State takes a value that owns its data; this type's name shows an origin or a parameter pack ({}), so it may borrow a value the App outlives: state_origin_local_raw.View[{}, {}]

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
