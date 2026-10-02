# Must not compile: the ToResponse twin of
# post_int_body_without_from_body.mojo repeats its body check and message
# (M2-009).
# Expected diagnostic (checked by scripts/check.sh): the handler's last parameter is the request body; its type must conform to FromBody

from muntin import App, Response, ToResponse


struct NotBody(Movable):
    var name: String

    def __init__(out self, name: String):
        self.name = name


struct User(ToResponse):
    var id: Int

    def __init__(out self, id: Int):
        self.id = id

    def to_response(var self) -> Response:
        return Response.text(String(self.id))


def h(id: Int, body: NotBody) -> User:
    return User(id)


def main():
    var app = App()
    app.post["/users/{id}"](h)
