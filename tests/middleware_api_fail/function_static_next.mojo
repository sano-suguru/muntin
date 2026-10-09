# Must not build (M3-035): `App.use` takes only a function generic over the
# origin of its `Next`; one written for a `Next` of a fixed, longer-lived
# origin does not register, so no registered middleware holds a `Next` that
# outlives the `App` borrow.
# Expected diagnostic (checked by scripts/check.sh): cannot be converted from 'def mw(var request: Request, var next: Next[ImmStaticOrigin]) raises thin -> Response' to 'Middleware'
from muntin import App, Next, Request, Response


def mw(
    var request: Request, var next: Next[ImmStaticOrigin]
) raises -> Response:
    return next^.run(request^)


def main():
    var app = App()
    app.use(mw)
