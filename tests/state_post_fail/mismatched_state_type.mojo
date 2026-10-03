# Must not compile: the handler's state type and the registered state's type
# are one inferred S (M3-006).
# Expected diagnostic (checked by scripts/check.sh): value passed to 'state' cannot be converted from 'State[Cache]' to 'State[Db]'
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


struct Cache(Movable):
    def __init__(out self):
        pass


def h(db: State[Db], id: Int, body: Note) -> String:
    return body.text


def main():
    var app = App()
    app.post["/x/{id}"](h, State(Cache()))
