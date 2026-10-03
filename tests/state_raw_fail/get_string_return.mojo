# Must not compile: a stateful raw handler returns Response, never String (M3-007).
# Expected diagnostic (checked by scripts/check.sh): cannot be converted from 'def h(db: State[Db], req: Request) thin -> String' to 'def(State[S], var Request) raises Never thin -> Response'
from muntin import App, Request, Response, State


struct Db(Movable):
    var n: Int

    def __init__(out self, n: Int):
        self.n = n


def h(db: State[Db], req: Request) -> String:
    return req.body


def main():
    var app = App()
    app.get["/x"](h, State(Db(1)))
