from muntin import App
from muntin_flare import Server, Tls


def hello() -> String:
    return "Hello, Mojo!"


def main() raises:
    var app = App()
    app.get["/"](hello)
    var server = Server.bind(
        "127.0.0.1",
        8443,
        tls=Tls(cert_file="cert.pem", key_file="key.pem"),
    )
    print("listening on https://127.0.0.1:" + String(server.port()))
    server.serve(app)
