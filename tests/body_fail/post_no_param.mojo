# Must not compile: a POST handler without a body parameter. It selects post's
# parameterless overload, whose rule check requires the body (M3-015).
# Expected diagnostic (checked by scripts/check.sh): constraint failed: a post handler takes the request body as its last parameter

from muntin import App, FromBody, Request, Response


struct CreateUser(FromBody):
    var name: String

    def __init__(out self, name: String):
        self.name = name

    @staticmethod
    def from_body(body: String) raises -> Self:
        return Self(body)


def h() -> String:
    return "x"


def main():
    var app = App()
    app.post["/users"](h)
