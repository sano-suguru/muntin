# Must not compile: a stateful raw handler declaring the plain value `Db`
# instead of `State[Db]` (M3-007) selects no stateful overload (M3-015).
# Expected diagnostic (checked by scripts/check.sh): cannot be converted from 'def h(db: Db, req: Request) thin -> Response' to 'def(State[S], var A) raises Never thin -> Response'
from muntin import App, Request, Response, State


struct Db(Movable):
    var n: Int

    def __init__(out self, n: Int):
        self.n = n


def h(db: Db, req: Request) -> Response:
    return Response(200, req.body.copy())


def main():
    var app = App()
    app.get["/x"](h, State(Db(1)))
