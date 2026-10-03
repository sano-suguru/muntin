# Must not compile: a state argument for a raw handler that takes none has no overload; the state is never silently ignored (M3-007).
# Expected diagnostic (checked by scripts/check.sh): cannot be converted from 'def h(req: Request) thin -> Response' to 'def(State[S], var Request) raises Never thin -> Response'
from muntin import App, Request, Response, State


struct Db(Movable):
    var n: Int

    def __init__(out self, n: Int):
        self.n = n


def h(req: Request) -> Response:
    return Response.text(req.body)


def main():
    var app = App()
    app.get["/x"](h, State(Db(1)))
