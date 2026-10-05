# Must not compile: production `post` takes no `Headers` slot after a
# route value. The message is production's existing body-type rule for the
# last slot, which M3-016 keeps. Decision: docs/ARCHITECTURE.md, "Typed get
# header access decision (M3-016)".
# Expected diagnostic (checked by scripts/check.sh): constraint failed: the handler's last parameter is the request body; its type must conform to FromBody
from muntin import App, FromBody, Headers


struct Note(FromBody, Movable):
    var text: String

    def __init__(out self, var text: String):
        self.text = text^

    @staticmethod
    def from_body(body: String) raises -> Self:
        return Self(body)


def h(id: Int, headers: Headers) -> String:
    return "x"


def main():
    var app = App()
    app.post["/x/{id}"](h)
