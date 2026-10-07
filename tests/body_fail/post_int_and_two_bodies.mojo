# Must not compile: a route value and two bodies; a handler takes at most one
# body. Three request parameters select `post`'s slot-arity-3 overload, which
# reports the rule (M3-022; before it, no overload matched).
# Expected diagnostic (checked by scripts/check.sh): constraint failed: a post handler takes one request body, as its last parameter

from muntin import App, FromBody


struct UpdateUser(FromBody):
    var name: String

    def __init__(out self, name: String):
        self.name = name

    @staticmethod
    def from_body(body: String) raises -> Self:
        return Self(body)


def h(id: Int, a: UpdateUser, b: UpdateUser) -> String:
    return a.name


def main():
    var app = App()
    app.post["/users/{id}"](h)
