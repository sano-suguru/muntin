# Must not compile: a route value and a body, (Int, B). Decided in M2-005 but
# not part of the first body slice.
# Expected text is the compiler's note for App.post's String overload,
# def(var B) thin -> String with B: FromBody (M2-006); the ToResponse
# overload (M2-008) adds a second note, so the call is a 'no matching method'.
# Expected diagnostic (checked by scripts/check.sh): value passed to 'handler' cannot be converted from 'def h(id: Int, body: CreateUser) thin -> String' to 'def(var B) thin -> String'

from muntin import App, FromBody, Request, Response


struct CreateUser(FromBody):
    var name: String

    def __init__(out self, name: String):
        self.name = name

    @staticmethod
    def from_body(body: String) raises -> Self:
        return Self(body)


def h(id: Int, body: CreateUser) -> String:
    return body.name


def main():
    var app = App()
    app.post["/users/{id}"](h)
