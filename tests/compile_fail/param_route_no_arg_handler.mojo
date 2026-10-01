# Must not compile: a route with a path parameter, a handler that takes none.
# Expected diagnostic (checked by scripts/check.sh): route declares a path parameter but the handler takes none

from muntin import App


def hello() -> String:
    return "hello"


def get_user(id: Int) -> String:
    return String(id)


def main():
    var app = App()
    app.get["/users/{id}"](hello)
