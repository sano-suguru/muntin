# Must not compile: a parameter segment with an empty name.
# Expected diagnostic (checked by scripts/check.sh): malformed route literal

from muntin import App


def hello() -> String:
    return "hello"


def get_user(id: Int) -> String:
    return String(id)


def main():
    var app = App()
    app.get["/users/{}"](get_user)
