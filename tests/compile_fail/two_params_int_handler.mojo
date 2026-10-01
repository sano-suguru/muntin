# Must not compile: two path parameters for a one-parameter handler.
# Expected diagnostic (checked by scripts/check.sh): handler takes one Int path parameter; route must declare one

from muntin import App


def hello() -> String:
    return "hello"


def get_user(id: Int) -> String:
    return String(id)


def main():
    var app = App()
    app.get["/users/{id}/posts/{post}"](get_user)
