# Must not compile: a handler with two parameters. Not a supported shape.
# Expected diagnostic (checked by scripts/check.sh): value passed to 'handler' cannot be converted from 'def add(a: Int, b: Int) thin -> String' to 'def(Int) thin -> String'

from muntin import App


def add(a: Int, b: Int) -> String:
    return String(a + b)


def main():
    var app = App()
    app.get["/add/{a}/{b}"](add)
