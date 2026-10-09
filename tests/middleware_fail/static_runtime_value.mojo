# Must not compile (M3-034): candidate A' takes a compile-time value, so a
# middleware built from a runtime value cannot be registered with it.
# Expected diagnostic (checked by scripts/check.sh): cannot use a dynamic value in call argument
from muntin import App, Request, Response
from middleware_spike import Middleware, MwApp, Next


@fieldwise_init
struct Tag(ImplicitlyCopyable, Middleware):
    var value: String

    def handle(self, var request: Request, var next: Next) raises -> Response:
        return next^.run(request^)


def main():
    var app = MwApp(App())
    var value = String("runtime")
    app.use[Tag(value)]()
