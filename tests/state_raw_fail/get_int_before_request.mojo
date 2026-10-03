# Must not compile: the Request is the parameter right after the State; an Int between them makes no raw shape (M3-007).
# Expected diagnostic (checked by scripts/check.sh): cannot be converted from 'def h(db: State[Db], n: Int, req: Request) thin -> Response' to 'def(State[S], var Request) raises Never thin -> Response'
from muntin import App, Request, Response, State


struct Db(Movable):
    var n: Int

    def __init__(out self, n: Int):
        self.n = n


def h(db: State[Db], n: Int, req: Request) -> Response:
    return Response.text(req.body)


def main():
    var app = App()
    app.get["/x/{id}"](h, State(Db(1)))
