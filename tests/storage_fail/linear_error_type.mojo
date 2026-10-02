# Must not compile: a handler whose error type is linear. Muntin catches and
# drops a handler error, so the overloads bound the inferred error type by
# `Deinitable` (M2-010); a type that must be explicitly consumed is rejected
# at registration.
# Expected diagnostic (checked by scripts/check.sh): argument type 'Linear' does not conform to trait 'Deinitable'

from muntin import App


@explicit_destroy("must be consumed")
struct Linear(Deinitable where False):
    var x: Int

    def __init__(out self, x: Int):
        self.x = x

    def done(deinit self):
        pass


def fail() raises Linear -> String:
    raise Linear(1)


def main():
    var app = App()
    app.get["/fail"](fail)
