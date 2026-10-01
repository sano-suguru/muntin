# Must not compile: a raising body handler. Handler errors need the
# application-error model; until then every raise is an extraction failure.
# Expected text is the compiler's: App.post has one overload,
# def(var B) thin -> String with B: FromBody (M2-006).
# Expected diagnostic (checked by scripts/check.sh): invalid call to 'post': value passed to 'handler' cannot be converted from 'def h(body: CreateUser) raises thin -> String' to 'def(var B) thin -> String'

from muntin import App, FromBody, Request, Response


struct CreateUser(FromBody):
    var name: String

    def __init__(out self, name: String):
        self.name = name

    @staticmethod
    def from_body(body: String) raises -> Self:
        return Self(body)


def h(body: CreateUser) raises -> String:
    return body.name


def main():
    var app = App()
    app.post["/users"](h)
