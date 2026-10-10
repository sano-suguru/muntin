# Hello World. Muntin has no public run API yet (`app.run()` is an M3 target),
# so this drives the application through the in-memory TestClient.
from muntin import App
from muntin.testing import TestClient


def hello() -> String:
    return "hello"


def main() raises:
    var app = App()
    app.get["/hello"](hello)

    var response = TestClient(app).get("/hello")
    print(response.status, response.text())
