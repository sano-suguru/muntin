# Must not compile: a body handler on GET. Body-taking registrations belong to
# App.post; the handler selects get's one-slot overload, whose rule check
# rejects a body there (M3-015).
# Expected diagnostic (checked by scripts/check.sh): constraint failed: a get handler takes no request body

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
