# Must not compile: a stateful raw handler with a parameter after the Request
# (M3-007). It selects get's stateful two-slot overload, whose rule check
# reports the raw rule (M3-015).
# Expected diagnostic (checked by scripts/check.sh): constraint failed: a stateful raw get handler takes State first, then only the Request, and returns Response
from muntin import App, Request, Response, State


struct Db(Movable):
    var n: Int

    def __init__(out self, n: Int):
        self.n = n


def h(db: State[Db], req: Request, n: Int) -> Response:
    return Response(200, req.body.copy())


def main():
    var app = App()
    app.get["/x"](h, State(Db(1)))
