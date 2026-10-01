# Hello World. Muntin has no network backend yet (`app.run()` arrives with
# M1), so this drives the application through the in-memory TestClient.
from muntin import App
from muntin.testing import TestClient


def hello() -> String:
    return "hello"


def main():
    var app = App()
    app.get["/hello"](hello)

    var response = TestClient(app).get("/hello")
    print(response.status, response.text())
