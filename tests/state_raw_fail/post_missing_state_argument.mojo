# Must not compile: a stateful raw handler registered without its state
# (M3-007) selects post's stateless two-slot overload, whose rule check
# reports the State rule (M3-015).
# Expected diagnostic (checked by scripts/check.sh): constraint failed: State is injected application state, not the request body; a stateful post handler takes State first and the body last, and the state is the registration's second argument
from muntin import App, Request, Response, State


struct Db(Movable):
    var n: Int

    def __init__(out self, n: Int):
        self.n = n


def h(db: State[Db], req: Request) -> Response:
    return Response(200, req.body.copy())


def main():
    var app = App()
    app.post["/x"](h)
