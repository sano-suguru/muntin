# Must not compile: a lone String on a POST route with no placeholder. String
# is a route value, never the body (M3-014), so the handler is bodyless and
# its value needs a placeholder (M3-048).
# Expected diagnostic (checked by scripts/check.sh): handler takes one String parameter; route must declare exactly one path or query parameter

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
