# Must not build (M3-081): `mount` takes a Group, not an App.
# Expected diagnostic (checked by scripts/check.sh): mount takes a Group
from muntin import App


def main():
    var app = App()
    app.mount(App())
