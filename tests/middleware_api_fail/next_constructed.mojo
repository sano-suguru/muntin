# Must not build (M3-035): `Next`'s initializer takes only `_`-prefixed
# keyword arguments, so no public spelling builds a `Next` past the middleware
# (here, positional arguments; code that names `_` members can, M3-034).
# Expected diagnostic (checked by scripts/check.sh): candidate not viable: missing required argument: '_app'
from muntin import App, Next, Request, Response


def main():
    var app = App()
    var next = Next(app, 0)
    _ = next^.run(Request("GET", "/"))
