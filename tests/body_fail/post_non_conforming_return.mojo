# Must not compile: a body handler whose result is neither String-compatible
# nor a ToResponse type (M2-008). The generic overload bounds its result by
# the trait, so the call fails at registration and the note names the trait.
# Expected diagnostic (checked by scripts/check.sh): argument type 'Int' does not conform to trait 'ToResponse'

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
