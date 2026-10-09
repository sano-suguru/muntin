# Must not compile (M3-034): candidate F stores a thin function, so a closure
# that captures a runtime value (here, configuration) is not middleware; F's
# configuration is compile-time only (M3-001's `closure_handler_storage.mojo`
# for handlers).
# Expected diagnostic (checked by scripts/check.sh): cannot be converted from 'def(var request: Request, next: Next[*?]) raises -> Response' to 'MiddlewareFn'
from muntin import App, Request, Response
from middleware_spike import MwApp, Next


def main():
    var app = MwApp(App())
    var tag = String("runtime")

    def tagged(var request: Request, next: Next) raises {var tag} -> Response:
        var response = next(request^)
        response.headers.add("X-Tag", tag)
        return response^

    app.use(tagged)
