# Must not compile: a path placeholder on the body-only overload. The handler's
# one parameter is the body, so {id} would have no parameter to fill; (Int, B)
# is not supported.
# Expected diagnostic (checked by scripts/check.sh): handler takes only the request body; route must declare no path or query parameter

from muntin import App, FromBody, Request, Response


struct CreateUser(FromBody):
    var name: String

    def __init__(out self, name: String):
        self.name = name

    @staticmethod
    def from_body(body: String) raises -> Self:
        return Self(body)


def h(body: CreateUser) -> String:
    return body.name


def main():
    var app = App()
    app.post["/users/{id}"](h)
