# Must not compile: a String parameter. Not a supported handler shape, even
# though the generic box could store it: `String` is no slot kind yet, so
# get's one-slot overload reports the parameter (M3-015).
# Expected diagnostic (checked by scripts/check.sh): constraint failed: a get handler's parameter is an Int route value, the request Headers or, for a raw handler, the Request

from muntin import App


def greet(name: String) -> String:
    return "hi " + name


def main():
    var app = App()
    app.get["/greet/{name}"](greet)
