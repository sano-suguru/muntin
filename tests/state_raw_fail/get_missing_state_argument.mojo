# Must not compile: a stateful raw handler registered without its state matches no one-argument get overload (M3-007).
# Expected diagnostic (checked by scripts/check.sh): missing required argument: 'state'
from muntin import App, Request, Response, State


struct Db(Movable):
    var n: Int

    def __init__(out self, n: Int):
        self.n = n


def h(db: State[Db], req: Request) -> Response:
    return Response.text(req.body)


def main():
    var app = App()
    app.get["/x"](h)
