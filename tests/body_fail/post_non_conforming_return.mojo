# Must not compile: a body handler whose result is neither String-compatible
# nor a ToResponse type (M2-008). Every overload accepts its result only
# through the `where` clause, so the call fails at registration with the
# clause's violated constraint (M3-015).
# Expected diagnostic (checked by scripts/check.sh): identical(R, StringSpan[ImmStaticOrigin])

from muntin import App, FromBody


struct CreateUser(FromBody):
    var name: String

    def __init__(out self, name: String):
        self.name = name

    @staticmethod
    def from_body(body: String) raises -> Self:
        return Self(body)


def h(body: CreateUser) -> Int:
    return 1


def main():
    var app = App()
    app.post["/users"](h)
