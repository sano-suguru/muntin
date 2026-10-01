# Must not compile: a query parameter for a handler that takes none.
# Expected diagnostic (checked by scripts/check.sh): route declares a query parameter but the handler takes none

from muntin import App


def hello() -> String:
    return "hello"


def list_items(limit: Int) -> String:
    return String(limit)


def main():
    var app = App()
    app.get["/items?{limit}"](hello)
