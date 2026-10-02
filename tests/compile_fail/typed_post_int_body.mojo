# Must not compile: an Int body on the ToResponse overload of App.post
# (M2-008); rejected by type equality, as on the String overload.
# Expected diagnostic (checked by scripts/check.sh): Int is a route-value type, never the request body; the body parameter's type must conform to FromBody

from muntin import App, Response


def h(id: Int) -> Response:
    return Response.text(String(id), status=201)


def main():
    var app = App()
    app.post["/users"](h)
