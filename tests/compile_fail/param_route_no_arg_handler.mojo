# Must not compile: a route with a path parameter, a handler that takes none.
# Expected diagnostic (checked by scripts/check.sh): route declares a path parameter but the handler takes none
# README.md shows the `readme` regions (scripts/check_doc_examples.py).

from muntin import App


# example: readme
def hello() -> String:
    return "hello"


# example: end


def get_user(id: Int) -> String:
    return String(id)


def main():
    var app = App()
    # example: readme
    app.get["/users/{id}"](hello)
    # compile error: route declares a path parameter but the handler takes none
    # example: end
