# Must not compile: an Int body on App.post for a handler with a
# ToResponse result (M2-008); rejected as for a String result.
# Expected diagnostic (checked by scripts/check.sh): Int is a route-value type, never the request body; the body parameter's type must conform to FromBody

from muntin import App, Response


def h(id: Int) -> Response:
    return Response.text(String(id), status=201)


def main():
    var app = App()
    app.post["/users"](h)
