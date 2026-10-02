# Must not compile: a route value and a Request on App.post with a String
# result. The String (Int, B) overload's guard names the raw shape (M2-015).
# Expected diagnostic (checked by scripts/check.sh): Request is the whole request, not a body; a raw handler takes only the Request and returns Response

from muntin import App, Request


def h(id: Int, req: Request) -> String:
    return req.body


def main():
    var app = App()
    app.post["/hooks/{id}"](h)
