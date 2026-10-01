# Must not compile: a library-side Variant arm set cannot store a handler
# whose return type the application defines. The arm set is fixed where the
# library declares it; the handler's type is not one of its arms.
# Expected diagnostic (checked by scripts/check.sh): constraint failed: Type does not exist in Variant.

from std.utils import Variant

comptime _IntArg = def(Int) thin -> String


struct App(Movable):
    var _routes: List[Variant[_IntArg]]

    def __init__(out self):
        self._routes = List[Variant[_IntArg]]()

    def get[R: Copyable](mut self, handler: def(Int) thin -> R):
        self._routes.append(Variant[_IntArg](handler))


@fieldwise_init
struct User(Copyable):
    var id: Int


def get_user(id: Int) -> User:
    return User(id)


def main():
    var app = App()
    app.get(get_user)
