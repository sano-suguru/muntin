# Must not compile: stateful raw handlers are not production (out of scope
# until their own slice); `def(State[S], Request) -> Response` reaches the
# stateful ToResponse body overload with B = Request, whose guard answers
# (M3-006). The stateful raw slice replaces this fixture.
# Expected diagnostic (checked by scripts/check.sh): Request is the whole request, not a body
from muntin import App, FromBody, State, Request, Response


struct Db(Movable):
    var n: Int

    def __init__(out self, n: Int):
        self.n = n


struct Note(FromBody):
    var text: String

    def __init__(out self, text: String):
        self.text = text

    @staticmethod
    def from_body(body: String) raises -> Self:
        return Self(body)


def h(db: State[Db], req: Request) -> Response:
    return Response.text(req.body)


def main():
    var app = App()
    app.post["/x"](h, State(Db(1)))
