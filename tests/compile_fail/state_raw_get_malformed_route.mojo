# Must not compile: a stateful raw GET registration with a malformed route literal (M3-007).
# Expected diagnostic (checked by scripts/check.sh): malformed route literal
from muntin import App, Request, Response, State


struct Db(Movable):
    var n: Int

    def __init__(out self, n: Int):
        self.n = n


def h(db: State[Db], req: Request) -> Response:
    return Response(200, req.body.copy())


def main():
    var app = App()
    app.get["/x/{"](h, State(Db(1)))
