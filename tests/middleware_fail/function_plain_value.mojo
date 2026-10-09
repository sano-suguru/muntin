# Must not compile (M3-034): candidate F's `use` takes only a middleware
# function; a plain value is not one.
# Expected diagnostic (checked by scripts/check.sh): cannot be converted from 'IntLiteral[42]' to 'MiddlewareFn'
from muntin import App
from middleware_spike import MwApp


def main():
    var app = MwApp(App())
    app.use(42)
