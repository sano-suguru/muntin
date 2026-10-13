# Must not compile: one `Optional[Int]` and a type of no kind (`Form`) in the
# body position on `post` whose literal declares no placeholder. The one-value
# placeholder rule runs before the body rules, so the optional value's message
# wins over the body-type message (an `Int` there would make the handler
# bodyless, M3-048). Decision:
# docs/history/architecture-decisions.md, "Optional query values decision
# (M3-024)".
# Expected diagnostic (checked by scripts/check.sh): constraint failed: handler takes one Optional route value and the request body; route must declare exactly one query parameter and no path parameter
from muntin import App


struct Form(Movable):
    var name: String


def h(a: Optional[Int], b: Form) -> String:
    return b.name


def main():
    var app = App()
    app.post["/x"](h)
