# Must not compile: the registration takes a State handle, not the value (M3-007).
# Expected diagnostic (checked by scripts/check.sh): value passed to 'state' cannot be converted from 'Db' to 'State[Db]'
from muntin import App, Request, Response, State


struct Db(Movable):
    var n: Int

    def __init__(out self, n: Int):
        self.n = n


def h(db: State[Db], req: Request) -> Response:
    return Response(200, req.body.copy())


def main():
    var app = App()
    app.get["/x"](h, Db(1))
