# Must not compile (M3-034): candidate A takes only a value of a type that
# conforms to `Middleware`.
# Expected diagnostic (checked by scripts/check.sh): does not conform to trait 'Middleware'
from muntin import App
from middleware_spike import MwApp


@fieldwise_init
struct Plain(Movable):
    var value: Int


def main():
    var app = MwApp(App())
    app.use(Plain(1))
