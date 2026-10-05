# Must not compile: production `post` takes no `Headers` slot; header
# fields reach a typed post handler through a `WithHeaders[B]` body. The
# message is production's existing body-type rule, which M3-016 keeps for
# every `Headers` shape on `post`. Decision: docs/ARCHITECTURE.md, "Typed
# get header access decision (M3-016)".
# Expected diagnostic (checked by scripts/check.sh): constraint failed: the handler's parameter is the request body; its type must conform to FromBody
from muntin import App, FromBody, Headers


struct Note(FromBody, Movable):
    var text: String

    def __init__(out self, var text: String):
        self.text = text^

    @staticmethod
    def from_body(body: String) raises -> Self:
        return Self(body)


def h(headers: Headers) -> String:
    return "x"


def main():
    var app = App()
    app.post["/x"](h)
