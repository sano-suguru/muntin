# Must not compile: a stateful POST handler returning a ToResponse type with a
# second State after its route value, in the body slot (M3-006).
# Expected diagnostic (checked by scripts/check.sh): a handler takes at most one State, as its first parameter
from muntin import App, FromBody, Response, State, ToResponse


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


@fieldwise_init
struct Count(Movable, ToResponse):
    var n: Int

    def to_response(var self) -> Response:
        return Response.text(String(self.n))


def h(db: State[Db], id: Int, other: State[Db]) -> Count:
    return Count(id)


def main():
    var app = App()
    app.post["/x/{id}"](h, State(Db(1)))
