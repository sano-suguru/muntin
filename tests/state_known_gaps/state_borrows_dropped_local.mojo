# Must build: scripts/check.sh builds it, which shows only that the compiler
# accepts it. scripts/run_origin_gaps.sh runs it under AddressSanitizer and
# requires the report below, which shows that the request reads freed memory.
# Expected report: AddressSanitizer: heap-use-after-free
#
# Found by "Request context storage decision (M3-065)" in
# docs/history/architecture-decisions.md (pull request #118): a gap in
# production `State` today, issue #122. A route erases its `State[S]`, and
# `App`'s type does not carry the origins in `S`, so a state that borrows a
# local registers, the checker ends the local at its last use, and a later
# request reads it. It takes a handler instantiated with the local's origin, in
# safe code that names no `_` member.
#
# If this file stops building, registration refuses a state that borrows a
# local; if it stops reporting, the borrow is kept alive: either way, check
# #122's acceptance criteria and update docs/DX.md section 8 and
# docs/ARCHITECTURE.md.

from std.memory import OwnedPointer

from muntin import App, State
from muntin.testing import TestClient


struct View[o: Origin[mut=False]](Movable):
    var p: Pointer[Int, Self.o]

    def __init__(out self, ref[Self.o] x: Int):
        self.p = Pointer(to=x)


def show[o: Origin[mut=False]](view: State[View[o]]) -> String:
    return String(view[].p[])


@no_inline
def build(mut app: App):
    var token = OwnedPointer(42)
    app.get["/"](show[origin_of(token[])], State(View(token[])))


def main() raises:
    var app = App()
    build(app)
    var client = TestClient(app)
    _ = client.get("/")
