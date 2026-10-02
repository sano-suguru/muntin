# Must not compile: a raising (Int, B) handler with a ToResponse result.
# Expected text is the note for the ToResponse (Int, B) overload (M2-009).
# Expected diagnostic (checked by scripts/check.sh): value passed to 'handler' cannot be converted from 'def h(id: Int, body: UpdateUser) raises thin -> User' to 'def(Int, var B) thin -> User'

from muntin import App, FromBody, Response, ToResponse


struct UpdateUser(FromBody):
    var name: String

    def __init__(out self, name: String):
        self.name = name

    @staticmethod
    def from_body(body: String) raises -> Self:
        return Self(body)


struct User(ToResponse):
    var id: Int

    def __init__(out self, id: Int):
        self.id = id

    def to_response(var self) -> Response:
        return Response.text(String(self.id))


def h(id: Int, body: UpdateUser) raises -> User:
    return User(id)


def main():
    var app = App()
    app.post["/users/{id}"](h)
