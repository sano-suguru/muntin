# Must not compile: a handler with two Int parameters. Not a supported shape:
# get's two-slot overload reports that a get handler takes at most one route
# value (M3-015).
# Expected diagnostic (checked by scripts/check.sh): constraint failed: a get handler takes at most one Int route value

from muntin import App


def add(a: Int, b: Int) -> String:
    return String(a + b)


def main():
    var app = App()
    app.get["/add/{a}/{b}"](add)
