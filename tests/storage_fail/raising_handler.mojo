# Must not compile: a raising handler. The storage's internal invoker raises
# (argument conversion), but App.get accepts non-raising handlers only.
# Expected diagnostic (checked by scripts/check.sh): value passed to 'handler' cannot be converted from 'def get_user(id: Int) raises thin -> String' to 'def(Int) thin -> String'

from muntin import App


def get_user(id: Int) raises -> String:
    return String(id)


def main():
    var app = App()
    app.get["/users/{id}"](get_user)
