# Must not compile: the body before the route value, (B, Int). Binding is
# positional, route value first (M2-005); the handler selects post's two-slot
# overload, whose rule check reports that the body comes last (M3-015).
# Expected diagnostic (checked by scripts/check.sh): constraint failed: a post handler takes one request body, as its last parameter

from muntin import App, FromBody


struct UpdateUser(FromBody):
    var name: String

    def __init__(out self, name: String):
        self.name = name

    @staticmethod
    def from_body(body: String) raises -> Self:
        return Self(body)


def h(body: UpdateUser, id: Int) -> String:
    return body.name


def main():
    var app = App()
    app.post["/users/{id}"](h)
