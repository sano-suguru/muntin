# Must not build (M3-035): `App.use` takes only a middleware function; a plain
# value is not one.
# Expected diagnostic (checked by scripts/check.sh): cannot be converted from 'IntLiteral[42]' to 'Middleware'
from muntin import App


def main():
    var app = App()
    app.use(42)
