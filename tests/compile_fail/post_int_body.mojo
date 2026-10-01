# Must not compile: an Int handler parameter on a body-only POST route would
# sit in the body slot. App.post rejects a route-value type there by type
# equality, whatever conformances exist (M2-005).
# Expected diagnostic (checked by scripts/check.sh): Int is a route-value type, never the request body; the body parameter's type must conform to FromBody

from muntin import App, FromBody, Request, Response


struct CreateUser(FromBody):
    var name: String

    def __init__(out self, name: String):
        self.name = name

    @staticmethod
    def from_body(body: String) raises -> Self:
        return Self(body)


def h(id: Int) -> String:
    return String(id)


def main():
    var app = App()
    app.post["/users"](h)
