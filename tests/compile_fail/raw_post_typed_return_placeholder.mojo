# Must not compile: a `Request` handler with a non-`Response` result on a
# post route with a placeholder. The placeholder rule is reported first,
# before the `Request` rule (the rule order in `_post_rule`).
# Expected diagnostic (checked by scripts/check.sh): handler takes only the request body; route must declare no path or query parameter

from muntin import App, Request


def h(req: Request) -> String:
    return "x"


def main():
    var app = App()
    app.post["/x/{id}"](h)
