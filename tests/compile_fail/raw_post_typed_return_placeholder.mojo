# Must not compile: a `Request` handler with a non-`Response` result on a
# post route with a placeholder. The placeholder rule is reported first, as
# the per-shape body overload reported it before M3-015 (found by the
# M3-015 review: the first rule order reported the `Request` rule instead).
# Expected diagnostic (checked by scripts/check.sh): handler takes only the request body; route must declare no path or query parameter

from muntin import App, Request


def h(req: Request) -> String:
    return "x"


def main():
    var app = App()
    app.post["/x/{id}"](h)
