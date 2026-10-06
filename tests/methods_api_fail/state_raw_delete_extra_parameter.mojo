# Must not compile: a stateful raw `delete` handler takes only the `Request`
# after its `State`, as on `get`; the message names the method. Decision:
# docs/history/architecture-decisions.md, "HTTP methods decision (M3-020)".
# Expected diagnostic (checked by scripts/check.sh): constraint failed: a stateful raw delete handler takes State first, then only the Request, and returns Response
from muntin import App, Request, Response, State


struct P(Movable):
    var n: Int

    def __init__(out self, n: Int):
        self.n = n


def h(p: State[P], req: Request, id: Int) -> Response:
    return Response.text(req.path)


def main():
    var app = App()
    app.delete["/x"](h, State(P(1)))
