# Must not compile: a stateful raw handler declaring the plain value `Db` instead of `State[Db]` (M3-007).
# Expected diagnostic (checked by scripts/check.sh): cannot be converted from 'def h(db: Db, req: Request) thin -> Response' to 'def(State[S], var Request) raises Never thin -> Response'
from muntin import App, Request, Response, State


struct Db(Movable):
    var n: Int

    def __init__(out self, n: Int):
        self.n = n


def h(db: Db, req: Request) -> Response:
    return Response.text(req.body)


def main():
    var app = App()
    app.post["/x"](h, State(Db(1)))
