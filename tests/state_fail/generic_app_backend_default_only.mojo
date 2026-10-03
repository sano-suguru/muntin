# Must not compile: candidate B as `App[S]`. Binding the backend's field to
# the default (`App[]`) compiles, but then the backend serves only
# stateless apps; an `App[Db]` must make every backend generic over `S`
# (M3-001).
# Expected diagnostic (checked by scripts/check.sh): cannot be converted from 'App[Db]' to 'App'


struct NoState(Movable):
    def __init__(out self):
        pass


struct Db(Movable):
    var n: Int

    def __init__(out self, n: Int):
        self.n = n


struct App[S: Movable & Deinitable = NoState](Movable):
    var state: Self.S

    def __init__(out self, var state: Self.S):
        self.state = state^


struct Backend(Movable):
    var app: App[]

    def __init__(out self, var app: App[]):
        self.app = app^


def main():
    var stateless = Backend(App(NoState()))
    var stateful = Backend(App(Db(1)))
