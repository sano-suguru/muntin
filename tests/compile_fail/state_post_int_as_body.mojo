# Must not compile: State then a lone Int on a POST route with no
# placeholder: Int is a route value, never the body (M3-006), so the handler
# is bodyless and its value needs a placeholder (M3-048).
# Expected diagnostic (checked by scripts/check.sh): handler takes one Int parameter; route must declare exactly one path or query parameter
from muntin import App, FromBody, State


struct Db(Movable):
    var n: Int

    def __init__(out self, n: Int):
        self.n = n


struct Note(FromBody):
    var text: String

    def __init__(out self, text: String):
        self.text = text

    @staticmethod
    def from_body(body: String) raises -> Self:
        return Self(body)


def h(db: State[Db], id: Int) -> String:
    return String(id)


def main():
    var app = App()
    app.post["/x"](h, State(Db(1)))
