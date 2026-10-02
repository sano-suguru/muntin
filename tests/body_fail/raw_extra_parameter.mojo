# Must not compile: a raw handler with a second parameter on App.post. No
# overload takes it; the raw candidate's note names the accepted function
# type (M2-015).
# Expected diagnostic (checked by scripts/check.sh): cannot be converted from 'def h(req: Request, n: Int) thin -> Response' to 'def(var Request) raises Never thin -> Response'

from muntin import App, Request, Response


def h(req: Request, n: Int) -> Response:
    return Response.text(req.body)


def main():
    var app = App()
    app.post["/hooks/{n}"](h)
