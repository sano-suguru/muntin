# Must not compile: a stateful route-value-then-body POST handler returning a
# ToResponse type whose body type does not conform to FromBody (M3-006).
# Expected diagnostic (checked by scripts/check.sh): the handler's last parameter is the request body; its type must conform to FromBody or FromBytes
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


struct Plain(Movable):
    var name: String

    def __init__(out self, name: String):
        self.name = name


def h(db: State[Db], id: Int, body: Plain) -> Count:
    return Count(id)


def main():
    var app = App()
    app.post["/x/{id}"](h, State(Db(1)))
