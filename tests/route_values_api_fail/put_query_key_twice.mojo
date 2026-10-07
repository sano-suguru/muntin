# Must not compile: a literal that repeats a query key: both parameters
# would read the one key, so no request could give them different values. The
# shape passes every other rule. Decision:
# docs/history/architecture-decisions.md, "Several route values decision
# (M3-022)".
# Expected diagnostic (checked by scripts/check.sh): constraint failed: route declares a query parameter twice
from muntin import App, FromBody


struct Note(FromBody, Movable):
    var text: String

    def __init__(out self, var text: String):
        self.text = text^

    @staticmethod
    def from_body(body: String) raises -> Self:
        return Self(body)


def h(a: String, b: String, body: Note) -> String:
    return a + b


def main():
    var app = App()
    app.put["/x?{a}&{a}"](h)
