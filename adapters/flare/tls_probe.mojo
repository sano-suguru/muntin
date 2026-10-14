"""A TLS `Server` on a port the system chooses, for scripts/check_flare.sh to
ask with `openssl s_client` (M3-051): the TLS versions and ciphers it
accepts. It serves `build/tls/cert.pem` and `build/tls/key.pem`, prints
`listening on 127.0.0.1:<port>` once bound, and serves until it is
stopped."""

from muntin import App
from muntin_flare import Server, Tls


def hello() -> String:
    return "hello"


def main() raises:
    var app = App()
    app.get["/"](hello)
    var server = Server.bind(
        "127.0.0.1",
        0,
        tls=Tls(cert_file="build/tls/cert.pem", key_file="build/tls/key.pem"),
    )
    print("listening on 127.0.0.1:" + String(server.port()), flush=True)
    server.serve(app)
