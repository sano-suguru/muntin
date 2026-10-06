# Must not compile: `String` is a route value and never the request body
# (M3-014), so a post handler whose only parameter is a `String` is a body-only
# shape even where a placeholder could bind it, and the placeholder is
# reported. Without a placeholder it is the body-type message
# (tests/compile_fail/post_string_body.mojo). Decision:
# docs/history/architecture-decisions.md, "Route-value decoding and String
# route values decision (M3-018)".
# Expected diagnostic (checked by scripts/check.sh): constraint failed: handler takes only the request body; route must declare no path or query parameter
from muntin import App


def h(name: String) -> String:
    return name


def main():
    var app = App()
    app.post["/x/{a}"](h)
