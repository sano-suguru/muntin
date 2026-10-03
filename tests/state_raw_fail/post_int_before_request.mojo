# Must not compile: the Request is the parameter right after the State; an
# Int between them makes no raw shape (M3-007). The call reaches the stateful
# route-value-then-body overload with B = Request, whose guard names the
# stateful raw shape.
# Expected diagnostic (checked by scripts/check.sh): constraint failed: Request is the whole request, not a body; a stateful raw handler takes State first, then only the Request, and returns Response
from muntin import App, Request, Response, State


struct Db(Movable):
    var n: Int

    def __init__(out self, n: Int):
        self.n = n


def h(db: State[Db], n: Int, req: Request) -> Response:
    return Response.text(req.body)


def main():
    var app = App()
    app.post["/x/{id}"](h, State(Db(1)))
