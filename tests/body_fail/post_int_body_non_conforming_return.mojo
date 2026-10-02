# Must not compile: an (Int, B) handler whose result is neither
# String-compatible nor ToResponse. Expected text is the note for the
# ToResponse (Int, B) overload, naming the trait (M2-009).
# Expected diagnostic (checked by scripts/check.sh): value passed to 'handler' cannot be converted from 'def h(id: Int, body: UpdateUser) thin -> Int' to 'def(Int, var B) thin -> R', argument type 'Int' does not conform to trait 'ToResponse'

from muntin import App, FromBody


struct UpdateUser(FromBody):
    var name: String

    def __init__(out self, name: String):
        self.name = name

    @staticmethod
    def from_body(body: String) raises -> Self:
        return Self(body)


def h(id: Int, body: UpdateUser) -> Int:
    return id


def main():
    var app = App()
    app.post["/users/{id}"](h)
