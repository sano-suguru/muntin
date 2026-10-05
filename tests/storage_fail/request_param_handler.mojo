# Must not compile: a Request handler returning String on App.get. Raw
# handlers return Response only (M2-015); the handler selects get's one-slot
# overload, whose rule check reports the raw rule (M3-015).
# Expected diagnostic (checked by scripts/check.sh): constraint failed: a raw get handler takes only the Request and returns Response

from muntin import App, Request


def raw(req: Request) -> String:
    return req.path


def main():
    var app = App()
    app.get["/raw"](raw)
