# Must not compile: a stateful raw handler returns Response, never another
# ToResponse type (M3-007).
# Expected diagnostic (checked by scripts/check.sh): cannot be converted from 'def h(db: State[Db], req: Request) thin -> Echo' to 'def(State[S], var Request) raises Never thin -> Response'
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
    return Echo(req.body)


def main():
    var app = App()
    app.get["/x"](h, State(Db(1)))
