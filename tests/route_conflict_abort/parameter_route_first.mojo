# A parameter route registered before a static route it covers: the static
# route would be unreachable (`GET /users/me` answered 400 by `get_user`),
# so its registration aborts (M3-053, pull request #95).
# Expected diagnostic (checked by scripts/check.sh): route conflict: GET /users/me is registered after GET /users/{id}, which matches every request it matches; register GET /users/me first
from muntin import App


def get_user(id: Int) -> String:
    return String(id)


def me() -> String:
    return "me"


def main():
    var app = App()
    app.get["/users/{id}"](get_user)
    app.get["/users/me"](me)
