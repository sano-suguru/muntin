# Must not compile: the handler borrows the route's handle; `var db:
# State[Db]` does not convert to the registered function type (M3-007), so the
# call selects no overload (M3-015).
# Expected diagnostic (checked by scripts/check.sh): cannot be converted from 'def h(var db: State[Db], req: Request) thin -> Response' to 'def(State[S], var A) raises Never thin -> Response'
from muntin import App, Request, Response, State


struct Db(Movable):
    var n: Int

    def __init__(out self, n: Int):
        self.n = n


def h(var db: State[Db], req: Request) -> Response:
    return Response.text(req.body)


def main():
    var app = App()
    app.get["/x"](h, State(Db(1)))
