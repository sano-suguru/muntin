# Must not compile: an Int handler on a route without a path parameter.
# Expected diagnostic (checked by scripts/check.sh): handler takes one Int path parameter; route must declare one

from muntin import App


def hello() -> String:
    return "hello"


def get_user(id: Int) -> String:
    return String(id)


def main():
    var app = App()
    app.get["/users"](get_user)
