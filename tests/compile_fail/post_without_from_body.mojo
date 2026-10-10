# Must not compile: an application type used as the request body without
# conforming to FromBody. Muntin's registration owns the message.
# Expected diagnostic (checked by scripts/check.sh): the handler's parameter is the request body; its type must conform to FromBody or FromBytes

from muntin import App, FromBody, Request, Response


struct CreateUser(FromBody):
    var name: String

    def __init__(out self, name: String):
        self.name = name

    @staticmethod
    def from_body(body: String) raises -> Self:
        return Self(body)


struct Plain(Movable):
    var name: String

    def __init__(out self, name: String):
        self.name = name


def h(body: Plain) -> String:
    return body.name


def main():
    var app = App()
    app.post["/users"](h)
