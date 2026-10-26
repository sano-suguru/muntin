# Must not compile (M3-091): only a build with -D MUNTIN_OPENAPI
# links the operations, so a call without it would describe none.
# Expected diagnostic (checked by scripts/check.sh): openapi: build with -D MUNTIN_OPENAPI
from muntin import App


def hello() -> String:
    return "hi"


def main() raises:
    var app = App()
    app.get["/"](hello)
    print(app.openapi(title="T", version="1"))
