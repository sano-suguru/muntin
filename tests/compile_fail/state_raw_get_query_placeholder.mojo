# Must not compile: a stateful raw GET route declaring a query parameter; raw routes stay static (M3-007).
# Expected diagnostic (checked by scripts/check.sh): route declares a query parameter but the handler takes none
from muntin import App, Request, Response, State


struct Db(Movable):
    var n: Int

    def __init__(out self, n: Int):
        self.n = n


def h(db: State[Db], req: Request) -> Response:
    return Response.text(req.body)


def main():
    var app = App()
    app.get["/x?{id}"](h, State(Db(1)))
