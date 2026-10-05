# Must not compile: a route value and two bodies; a handler takes at most one
# body. Three request parameters select no overload (the largest slot arity is
# 2), so the call is a 'no matching method'; expected text is the note for
# post's two-slot candidate (M3-015).
# Expected diagnostic (checked by scripts/check.sh): value passed to 'handler' cannot be converted from 'def h(id: Int, a: UpdateUser, b: UpdateUser) thin -> String' to 'def(var A, var B) raises Never thin -> String'

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
