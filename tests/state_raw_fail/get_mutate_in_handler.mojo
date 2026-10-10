# Must not compile: state[] is read-only inside a registered stateful raw handler (M3-007).
# Expected diagnostic (checked by scripts/check.sh): expression must be mutable in assignment
from muntin import App, Request, Response, State


struct Db(Movable):
    var n: Int

    def __init__(out self, n: Int):
        self.n = n


def h(db: State[Db], req: Request) -> Response:
    db[].n = 2
    return Response(200, req.body.copy())


def main():
    var app = App()
    app.get["/x"](h, State(Db(1)))
