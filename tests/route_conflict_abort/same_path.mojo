# Two routes of one method whose paths differ only in placeholder names and
# the query: the later one would never be selected (M3-053, pull request #95).
# Expected diagnostic (checked by scripts/check.sh): route conflict: POST /items/{name} matches the same requests as POST /items/{id}, registered earlier (the query takes no part in selection)
from muntin import App


def by_id(id: Int) -> String:
    return String(id)


def by_name(name: String, limit: Int) -> String:
    return name


def main():
    var app = App()
    app.post["/items/{id}"](by_id)
    app.post["/items/{name}?{limit}"](by_name)
