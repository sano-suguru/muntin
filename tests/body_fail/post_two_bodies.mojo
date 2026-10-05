# Must not compile: two body parameters; a handler takes at most one body. It
# selects post's two-slot overload, whose rule check reports it (M3-015).
# Expected diagnostic (checked by scripts/check.sh): constraint failed: a post handler takes one request body, as its last parameter

from muntin import App, FromBody, Request, Response


struct CreateUser(FromBody):
    var name: String

    def __init__(out self, name: String):
        self.name = name

    @staticmethod
    def from_body(body: String) raises -> Self:
        return Self(body)


def h(a: CreateUser, b: CreateUser) -> String:
    return a.name


def main():
    var app = App()
    app.post["/users"](h)
