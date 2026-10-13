# Must not compile: post_int_body.mojo with a ToResponse result (M2-008):
# the same bodyless placeholder rule and message (M3-048).
# Expected diagnostic (checked by scripts/check.sh): handler takes one Int parameter; route must declare exactly one path or query parameter

from muntin import App, Response


def h(id: Int) -> Response:
    return Response.text(String(id), status=201)


def main():
    var app = App()
    app.post["/users"](h)
