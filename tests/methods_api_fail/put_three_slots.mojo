# Must not compile: Three request slots, no `State` and no state argument match
# none of `put`'s six overloads, so the compiler's own diagnostic names the
# method. Decision: docs/history/architecture-decisions.md, "HTTP methods
# decision (M3-020)".
# Expected diagnostic (checked by scripts/check.sh): no matching method in call to 'put'
from muntin import App, FromBody


struct Note(FromBody, Movable):
    var text: String

    def __init__(out self, var text: String):
        self.text = text^

    @staticmethod
    def from_body(body: String) raises -> Self:
        return Self(body)


def h(a: Int, b: Note, c: Note) -> String:
    return b.text


def main():
    var app = App()
    app.put["/x/{a}"](h)
