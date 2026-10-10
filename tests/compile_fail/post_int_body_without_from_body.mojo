# Must not compile: the second parameter of (Int, B) is the request body and
# its type does not conform to FromBody (M2-009).
# Expected diagnostic (checked by scripts/check.sh): the handler's last parameter is the request body; its type must conform to FromBody or FromBytes

from muntin import App, FromBody


struct NotBody(Movable):
    var name: String

    def __init__(out self, name: String):
        self.name = name


def h(id: Int, body: NotBody) -> String:
    return body.name


def main():
    var app = App()
    app.post["/users/{id}"](h)
