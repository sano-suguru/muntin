# Must not compile: a `String` in a post handler's body position is not a body
# (M3-014: `String` is a route value, never the body), so it gets the existing
# `FromBody` message, as any other non-body type there does. Decision:
# docs/history/architecture-decisions.md, "Route-value decoding and String
# route values decision (M3-018)".
# Expected diagnostic (checked by scripts/check.sh): constraint failed: the handler's last parameter is the request body; its type must conform to FromBody
from muntin import App


def h(name: String, body: String) -> String:
    return name + body


def main():
    var app = App()
    app.post["/x/{a}"](h)
