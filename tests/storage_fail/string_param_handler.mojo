# Must not compile: a String parameter. Not a supported handler shape, even
# though the generic box could store it.
# Expected diagnostic (checked by scripts/check.sh): value passed to 'handler' cannot be converted from 'def greet(name: String) thin -> String' to 'def(Int) thin -> String'

from muntin import App


def greet(name: String) -> String:
    return "hi " + name


def main():
    var app = App()
    app.get["/greet/{name}"](greet)
