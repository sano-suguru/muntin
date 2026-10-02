# Must not compile: the ToResponse twin of post_int_body_no_route_value.mojo
# repeats its route check and message (M2-009).
# Expected diagnostic (checked by scripts/check.sh): handler takes one Int parameter and the request body; route must declare exactly one path or query parameter

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


def h(id: Int, body: UpdateUser) -> User:
    return User(id)


def main():
    var app = App()
    app.post["/users"](h)
