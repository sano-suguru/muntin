# Must not compile: a path placeholder on the body-only ToResponse overload
# (M2-008).
# Expected diagnostic (checked by scripts/check.sh): handler takes only the request body; route must declare no path or query parameter

from muntin import App, FromBody, Response


struct CreateUser(FromBody):
    var name: String

    def __init__(out self, name: String):
        self.name = name

    @staticmethod
    def from_body(body: String) raises -> Self:
        return Self(body)


def h(body: CreateUser) -> Response:
    return Response.text(body.name, status=201)


def main():
    var app = App()
    app.post["/users/{id}"](h)
