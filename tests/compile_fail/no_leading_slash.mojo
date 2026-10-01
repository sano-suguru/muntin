# Must not compile: a route literal without a leading slash.
# Expected diagnostic (checked by scripts/check.sh): malformed route literal

from muntin import App


def hello() -> String:
    return "hello"


def get_user(id: Int) -> String:
    return String(id)


def main():
    var app = App()
    app.get["users/{id}"](get_user)
