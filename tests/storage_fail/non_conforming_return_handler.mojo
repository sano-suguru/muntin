# Must not compile: a GET handler whose result is neither String-compatible
# nor a ToResponse type (M2-008). The generic overload bounds its result by
# the trait, so the call fails at registration and the note names the trait.
# Expected diagnostic (checked by scripts/check.sh): argument type 'Int' does not conform to trait 'ToResponse'

from muntin import App


def count(id: Int) -> Int:
    return id


def main():
    var app = App()
    app.get["/count/{id}"](count)
