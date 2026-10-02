# Must not compile: (Int, B) on a route without a path or query placeholder;
# the Int would have no source (M2-009).
# Expected diagnostic (checked by scripts/check.sh): handler takes one Int parameter and the request body; route must declare exactly one path or query parameter

from muntin import App, FromBody


struct UpdateUser(FromBody):
    var name: String

    def __init__(out self, name: String):
        self.name = name

    @staticmethod
    def from_body(body: String) raises -> Self:
        return Self(body)


def h(id: Int, body: UpdateUser) -> String:
    return body.name


def main():
    var app = App()
    app.post["/users"](h)
