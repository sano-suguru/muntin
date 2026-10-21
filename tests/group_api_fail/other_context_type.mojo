# Must not build (M3-081): a handler of a Group takes no context type but the
# one its guard returns; another application type is of no slot kind.
# Expected diagnostic (checked by scripts/check.sh): a get handler's parameter is an Int or String route value, an Optional of one, a FromRouteValue type, the request Headers or, for a raw handler, the Request
from muntin import Group, Headers, State


struct Svc(Movable):
    var n: Int

    def __init__(out self):
        self.n = 0


@fieldwise_init
struct User(Movable):
    var name: String


def auth(svc: State[Svc], headers: Headers) raises -> User:
    return User("ada")


@fieldwise_init
struct Admin(Movable):
    var name: String


def me(admin: Admin) -> String:
    return admin.name


def main():
    var g = Group(auth, State(Svc()))
    g.get["/me"](me)
