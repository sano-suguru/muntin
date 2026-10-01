# Must not compile: an empty query key.
# Expected diagnostic (checked by scripts/check.sh): malformed route literal

from muntin import App


def hello() -> String:
    return "hello"


def list_items(limit: Int) -> String:
    return String(limit)


def main():
    var app = App()
    app.get["/items?{}"](list_items)
