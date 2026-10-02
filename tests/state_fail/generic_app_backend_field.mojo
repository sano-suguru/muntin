# Must not compile: candidate B as `App[S]`, even with a default. A backend
# that stores `App` by name (the Flare adapter's `MuntinHandler.app`,
# `TestClient`'s `Pointer[App, origin]`) no longer names a concrete type
# (M3-001; M2-012 rejected `App[on_error=m]` for the same coupling).
# Expected diagnostic (checked by scripts/check.sh): 'App[_]' is not concrete, use '[]' to bind missing parameters


struct NoState(Movable):
    def __init__(out self):
        pass


struct App[S: Movable & Deinitable = NoState](Movable):
    var state: Self.S

    def __init__(out self, var state: Self.S):
        self.state = state^


struct Backend(Movable):
    var app: App

    def __init__(out self, var app: App):
        self.app = app^


def main():
    var b = Backend(App(NoState()))
