# Must not compile: the query value declared before the path value. Path
# placeholders bind first, so the first value binds {id}. Decision: docs/history/architecture-decisions.md, "Named route values
# decision (M3-050)".
# Expected diagnostic (checked by scripts/check.sh): constraint failed: route value 1 is Param["q"] but binds {id}; route values bind the path parameters left to right, then the query parameters
from muntin import App, FromBody, Param


struct Note(FromBody, Movable):
    var text: String

    def __init__(out self, var text: String):
        self.text = text^

    @staticmethod
    def from_body(body: String) raises -> Self:
        return Self(body)


def h(q: Param["q", String], id: Param["id", Int], body: Note) -> String:
    return body.text


def main():
    var app = App()
    app.put["/u/{id}?{q}"](h)
