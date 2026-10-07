# Must not compile: `Optional[Int]` as `post`'s only parameter is its body,
# and an `Optional` is no `FromBody`: the body message, unchanged by M3-025.
# Decision: docs/history/architecture-decisions.md, "Optional query values
# decision (M3-024)".
# Expected diagnostic (checked by scripts/check.sh): constraint failed: the handler's parameter is the request body; its type must conform to FromBody
from muntin import App


def h(body: Optional[Int]) -> String:
    return "x"


def main():
    var app = App()
    app.post["/x"](h)
