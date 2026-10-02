# Must not compile: a raw Request parameter on App.post. Request is not a body
# type, and a raw handler returns Response. The M2-014 production slice
# keeps this fixture and changes its expected text to the body overloads'
# Request guard (docs/ARCHITECTURE.md, "Raw Request decision (M2-014)").
# Expected diagnostic (checked by scripts/check.sh): the handler's parameter is the request body; its type must conform to FromBody

from muntin import App, FromBody, Request, Response


struct CreateUser(FromBody):
    var name: String

    def __init__(out self, name: String):
        self.name = name

    @staticmethod
    def from_body(body: String) raises -> Self:
        return Self(body)


def h(request: Request) -> String:
    return request.body


def main():
    var app = App()
    app.post["/users"](h)
