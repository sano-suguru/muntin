# Must not build (M3-081): an App's route has no guard, so a handler that takes
# a context type does not register on it.
# Expected diagnostic (checked by scripts/check.sh): a get handler's parameter is an Int or String route value, an Optional of one, a FromRouteValue type, the request Headers or, for a raw handler, the Request
from muntin import App


@fieldwise_init
struct User(Movable):
    var name: String


def me(user: User) -> String:
    return user.name


def main():
    var app = App()
    app.get["/me"](me)
