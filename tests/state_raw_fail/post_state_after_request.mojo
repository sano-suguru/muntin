# Must not compile: State is the first parameter of a stateful raw handler,
# never after the Request (M3-007). The stateful overloads fix `State[S]`
# first, so the call selects no overload (M3-015).
# Expected diagnostic (checked by scripts/check.sh): cannot be converted from 'def h(req: Request, db: State[Db]) thin -> Response' to 'def(State[S], var A) raises Never thin -> Response'
from muntin import App, Request, Response, State


struct Db(Movable):
    var n: Int

    def __init__(out self, n: Int):
        self.n = n


def h(req: Request, db: State[Db]) -> Response:
    return Response.text(req.body)


def main():
    var app = App()
    app.post["/x"](h, State(Db(1)))
