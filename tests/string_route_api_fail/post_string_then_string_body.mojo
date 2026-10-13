# Must not compile: a `String` in a post handler's last position is not a body
# (M3-014, M3-018) but a route value, so (String, String) on one placeholder
# is a bodyless handler with two route values, reported for its placeholders
# (M3-048).
# Decision: docs/history/architecture-decisions.md, "Bodyless typed post,
# # put and patch handlers decision (M3-048)".
# Expected diagnostic (checked by scripts/check.sh): handler takes two route values; route must declare exactly two path or query parameters
from muntin import App


def h(name: String, body: String) -> String:
    return name + body


def main():
    var app = App()
    app.post["/x/{a}"](h)
