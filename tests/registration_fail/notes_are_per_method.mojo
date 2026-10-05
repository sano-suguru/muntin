# Must not compile, and pins that Mojo 1.1.0's ten-note budget is per
# method name: a failing call to `put`, whose ten overloads sit beside ten
# `get` overloads, still prints the note of `put`'s tenth candidate
# ('UInt16'). So a new HTTP method is its own overload set and fits the
# budget without restructuring, and the selected design's per-method sets
# are measured separately (docs/ARCHITECTURE.md, "Registration structure
# decision (M3-014)"). `get`'s overloads take a second parameter so that
# renaming every `put` to `get` yields twenty distinct overloads in one
# set: that note is then omitted (`(10 more notes omitted.)`).
# Expected diagnostic (checked by scripts/check.sh): cannot be converted from 'Other' to 'UInt16'


struct Registry:
    def __init__(out self):
        pass

    def get(self, value: Int, extra: Int):
        pass

    def get(self, value: String, extra: Int):
        pass

    def get(self, value: Bool, extra: Int):
        pass

    def get(self, value: Float64, extra: Int):
        pass

    def get(self, value: UInt8, extra: Int):
        pass

    def get(self, value: Int8, extra: Int):
        pass

    def get(self, value: Int16, extra: Int):
        pass

    def get(self, value: Int32, extra: Int):
        pass

    def get(self, value: Int64, extra: Int):
        pass

    def get(self, value: UInt32, extra: Int):
        pass

    def put(self, value: Int):
        pass

    def put(self, value: String):
        pass

    def put(self, value: Bool):
        pass

    def put(self, value: Float64):
        pass

    def put(self, value: UInt8):
        pass

    def put(self, value: Int8):
        pass

    def put(self, value: Int16):
        pass

    def put(self, value: Int32):
        pass

    def put(self, value: Int64):
        pass

    def put(self, value: UInt16):
        pass


struct Other:
    def __init__(out self):
        pass


def main():
    var r = Registry()
    r.put(Other())
