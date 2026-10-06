# Must not compile: four request parameters match none of `put`'s eight
# overloads (the largest slot arity is 3), so the compiler's own diagnostic
# names the method. Decision:
# docs/history/architecture-decisions.md, "Several route values decision
# (M3-022)".
# Expected diagnostic (checked by scripts/check.sh): no matching method in call to 'put'
from muntin import App, FromBody


struct Note(FromBody, Movable):
    var text: String

    def __init__(out self, var text: String):
        self.text = text^

    @staticmethod
    def from_body(body: String) raises -> Self:
        return Self(body)


def h(a: Int, b: Int, c: Int, body: Note) -> String:
    return body.text


def main():
    var app = App()
    app.put["/x/{a}/{b}/{c}"](h)
