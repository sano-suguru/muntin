# Must not compile: a raw String body. String does not conform to FromBody,
# and it is a route value, never the body (M3-014); with a placeholder the
# shape is reported for its placeholder instead
# (tests/string_route_api_fail/post_string_alone_with_placeholder.mojo).
# Expected diagnostic (checked by scripts/check.sh): the handler's parameter is the request body; its type must conform to FromBody or FromBytes

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
