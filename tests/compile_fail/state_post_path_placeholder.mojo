# Must not compile: a stateful body-only POST handler on a route with a path
# parameter (M3-006). The state is not a route value.
# Expected diagnostic (checked by scripts/check.sh): handler takes only the request body; route must declare no path or query parameter
from muntin import App, FromBody, State


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


def h(db: State[Db], body: Note) -> String:
    return body.text


def main():
    var app = App()
    app.post["/x/{id}"](h, State(Db(1)))
