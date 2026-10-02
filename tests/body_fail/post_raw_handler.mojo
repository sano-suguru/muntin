# Must not compile: a raw Request -> Response handler on App.post. Since
# M2-008 it reaches the ToResponse overload with B = Request (Response
# conforms to ToResponse) and fails on that overload's FromBody check.
# Decided in M2-014 (docs/ARCHITECTURE.md, "Raw Request decision (M2-014)"): the
# production slice adds a raw overload that this call selects, and this
# fixture retires into a positive test.
# Expected diagnostic (checked by scripts/check.sh): constraint failed: the handler's parameter is the request body; its type must conform to FromBody

from muntin import App, FromBody, Request, Response


struct CreateUser(FromBody):
    var name: String

    def __init__(out self, name: String):
        self.name = name

    @staticmethod
    def from_body(body: String) raises -> Self:
        return Self(body)


def h(request: Request) -> Response:
    return Response.text(request.body)


def main():
    var app = App()
    app.post["/users"](h)
