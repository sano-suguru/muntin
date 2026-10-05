# Must not compile: a GET handler whose result is neither String-compatible
# nor a ToResponse type (M2-008). Every overload accepts its result only
# through the `where` clause, so the call fails at registration with the
# clause's violated constraint (M3-015).
# Expected diagnostic (checked by scripts/check.sh): identical(R, StringSpan[ImmStaticOrigin])

from muntin import App


def count(id: Int) -> Int:
    return id


def main():
    var app = App()
    app.get["/count/{id}"](count)
