# Must not compile: a body type without FromBody conformance on App.post,
# for a handler with a ToResponse result (M2-008).
# Expected diagnostic (checked by scripts/check.sh): the handler's parameter is the request body; its type must conform to FromBody

from muntin import App, Response


struct CreateUser(Movable):
    var name: String

    def __init__(out self, name: String):
        self.name = name


def h(body: CreateUser) -> Response:
    return Response.text(body.name, status=201)


def main():
    var app = App()
    app.post["/users"](h)
