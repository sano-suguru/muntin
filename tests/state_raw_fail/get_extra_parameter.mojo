# Must not compile: a stateful raw handler with a parameter after the Request (M3-007).
# Expected diagnostic (checked by scripts/check.sh): cannot be converted from 'def h(db: State[Db], req: Request, n: Int) thin -> Response' to 'def(State[S], var Request) raises Never thin -> Response'
from muntin import App, Request, Response, State


struct Db(Movable):
    var n: Int

    def __init__(out self, n: Int):
        self.n = n


def h(db: State[Db], req: Request, n: Int) -> Response:
    return Response.text(req.body)


def main():
    var app = App()
    app.get["/x"](h, State(Db(1)))
