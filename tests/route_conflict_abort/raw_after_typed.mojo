# A raw route is a route like any other: a static raw route after a typed
# parameter route that covers it aborts (M3-052, pull request #95).
# Expected diagnostic (checked by scripts/check.sh): route conflict: DELETE /files/all is registered after DELETE /files/{name}, which matches every request it matches; register DELETE /files/all first
from muntin import App, Request, Response


def remove(name: String) -> String:
    return name


def remove_all(req: Request) -> Response:
    return Response.text("all")


def main():
    var app = App()
    app.delete["/files/{name}"](remove)
    app.delete["/files/all"](remove_all)
