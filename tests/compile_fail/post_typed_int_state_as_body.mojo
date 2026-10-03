# Must not compile: as post_int_state_as_body, with a ToResponse result
# (M3-006).
# Expected diagnostic (checked by scripts/check.sh): State is injected application state, not the request body; a stateful post handler takes State first and the body last, and the state is the registration's second argument
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


def h(id: Int, db: State[Db]) -> Count:
    return Count(db[].n + id)


def main():
    var app = App()
    app.post["/x?{id}"](h)
