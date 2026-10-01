# Must not compile: a body type bound to a route-value slot. Route values are
# `Int`, body types conform to FromBody, and the two sets are disjoint, so
# position mistakes fail at registration.
# Expected diagnostic (checked by scripts/check.sh): constraint failed: route declares a path or query parameter; the handler parameter bound to it must be Int

from extraction_spike import ExtractApp, FromBody


struct CreateUser(FromBody):
    var name: String

    def __init__(out self, name: String):
        self.name = name

    @staticmethod
    def from_body(body: String) raises -> Self:
        return Self(body)


def create_user(body: CreateUser) -> String:
    return body.name


def main():
    var app = ExtractApp()
    app.post["/users/{id}"](create_user)
