# Must not compile: a body handler on GET. Body-taking registrations belong to
# App.post; App.get accepts only def() and def(Int) handlers.
# Expected diagnostic (checked by scripts/check.sh): value passed to 'handler' cannot be converted from 'def h(body: CreateUser) thin -> String' to 'def(Int) raises Never thin -> String'

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
    app.get["/users"](h)
