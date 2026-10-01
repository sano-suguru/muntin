# Must not compile: a raw String body. String does not conform to FromBody;
# a String body is out of scope until source binding is explicit (M2-005
# revisit conditions).
# Expected diagnostic (checked by scripts/check.sh): the handler's parameter is the request body; its type must conform to FromBody

from muntin import App, FromBody, Request, Response


struct CreateUser(FromBody):
    var name: String

    def __init__(out self, name: String):
        self.name = name

    @staticmethod
    def from_body(body: String) raises -> Self:
        return Self(body)


def h(body: String) -> String:
    return body


def main():
    var app = App()
    app.post["/users"](h)
