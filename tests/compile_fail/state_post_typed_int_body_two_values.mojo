# Must not compile: a stateful POST handler taking one route value and a body,
# returning a ToResponse type, on a route with two parameters (M3-006).
# Expected diagnostic (checked by scripts/check.sh): handler takes one Int parameter and the request body; route must declare exactly one path or query parameter
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


def h(db: State[Db], id: Int, body: Note) -> Count:
    return Count(id)


def main():
    var app = App()
    app.post["/x/{id}?{limit}"](h, State(Db(1)))
