# Must not build (M3-035): as `next_constructed.mojo`, with public keyword
# names instead of positional arguments.
# Expected diagnostic (checked by scripts/check.sh): candidate not viable: missing required argument: '_app'
from muntin import App, Next, Request, Response


def main():
    var app = App()
    var next = Next(app=app, index=0)
    _ = next^.run(Request("GET", "/"))
