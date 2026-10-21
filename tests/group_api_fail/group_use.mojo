# Must not build (M3-081): a Group takes no middleware; middleware registered
# on the App wraps its mounted routes.
# Expected diagnostic (checked by scripts/check.sh): a Group takes no middleware: register it on the App
from muntin import Group, Headers, Next, Request, Response, State


struct Svc(Movable):
    var n: Int

    def __init__(out self):
        self.n = 0


@fieldwise_init
struct User(Movable):
    var name: String


def auth(svc: State[Svc], headers: Headers) raises -> User:
    return User("ada")


def tag(var request: Request, var next: Next) raises -> Response:
    return next^.run(request^)


def main():
    var g = Group(auth, State(Svc()))
    g.use(tag)
