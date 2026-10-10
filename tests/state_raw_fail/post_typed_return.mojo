# Must not compile: a stateful raw handler returns Response, never another
# ToResponse type (M3-007). The call reaches the stateful ToResponse body
# overload with B = Request, whose guard names the stateful raw shape.
# Expected diagnostic (checked by scripts/check.sh): constraint failed: Request is the whole request, not a body; a stateful raw handler takes State first, then only the Request, and returns Response
from muntin import App, Request, Response, State, ToResponse


struct Db(Movable):
    var n: Int

    def __init__(out self, n: Int):
        self.n = n


@fieldwise_init
struct Echo(Movable, ToResponse):
    var text: String

    def to_response(var self) -> Response:
        return Response.text(self.text)


def h(db: State[Db], req: Request) -> Echo:
    return Echo(req.path)


def main():
    var app = App()
    app.post["/x"](h, State(Db(1)))
