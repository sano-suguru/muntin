# Must not compile: the handler's state type and the registered state's type are one inferred S (M3-007).
# Expected diagnostic (checked by scripts/check.sh): value passed to 'state' cannot be converted from 'State[Cache]' to 'State[Db]'
from muntin import App, Request, Response, State


struct Db(Movable):
    var n: Int

    def __init__(out self, n: Int):
        self.n = n


struct Cache(Movable):
    def __init__(out self):
        pass


def h(db: State[Db], req: Request) -> Response:
    return Response(200, req.body.copy())


def main():
    var app = App()
    app.get["/x"](h, State(Cache()))
