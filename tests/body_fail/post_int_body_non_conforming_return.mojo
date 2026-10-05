# Must not compile: an (Int, B) handler whose result is neither
# String-compatible nor ToResponse. Every overload accepts its result only
# through the `where` clause, so the call is a 'no matching method' and the
# two-slot candidate's note is the clause's violated constraint (M3-015).
# Expected diagnostic (checked by scripts/check.sh): identical(R, StringSpan[ImmStaticOrigin])

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
