# Must not build (M3-035): `App.use` stores a thin function, so a closure that
# captures a runtime value (here, configuration) is not middleware;
# configuration is compile-time only.
# Expected diagnostic (checked by scripts/check.sh): cannot be converted from 'def(var request: Request, var next: Next[*?]) raises -> Response' to 'Middleware'
from muntin import App, Next, Request, Response


def main():
    var app = App()
    var tag = String("runtime")

    def tagged(
        var request: Request, var next: Next
    ) raises {var tag} -> Response:
        var response = next^.run(request^)
        response.headers.add("X-Tag", tag)
        return response^

    app.use(tagged)
