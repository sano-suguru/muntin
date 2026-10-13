# Must not compile: a repeated query key on a shape that also breaks a body
# rule (a last slot of no kind, `Form`; an `Int` there would make the handler
# bodyless, M3-048) reports the body rule: the distinct-query-keys rule runs only for a
# shape every other rule accepts, so no existing message changes. Decision:
# docs/history/architecture-decisions.md, "Several route values decision
# (M3-022)".
# Expected diagnostic (checked by scripts/check.sh): constraint failed: the handler's last parameter is the request body; its type must conform to FromBody or FromBytes
from muntin import App


struct Form(Movable):
    var name: String


def h(a: String, b: String, c: Form) -> String:
    return a + b


def main():
    var app = App()
    app.put["/x?{a}&{a}"](h)
