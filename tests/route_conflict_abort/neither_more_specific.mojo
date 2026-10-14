# Two routes that both match `/a/b` and neither of which covers the other:
# no order makes the first match the most specific one (M3-052, pull
# request #95).
# Expected diagnostic (checked by scripts/check.sh): route conflict: PUT /{y}/b and PUT /a/{x}, registered earlier, both match some requests and neither is more specific
from muntin import App


def one(v: String) -> String:
    return v


def main():
    var app = App()
    app.put["/a/{x}"](one)
    app.put["/{y}/b"](one)
