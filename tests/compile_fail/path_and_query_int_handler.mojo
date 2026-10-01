# Must not compile: a path and a query parameter for a one-parameter handler.
# Expected diagnostic (checked by scripts/check.sh): handler takes one Int parameter; route must declare exactly one path or query parameter

from muntin import App


def hello() -> String:
    return "hello"


def list_items(limit: Int) -> String:
    return String(limit)


def main():
    var app = App()
    app.get["/users/{id}?{limit}"](list_items)
