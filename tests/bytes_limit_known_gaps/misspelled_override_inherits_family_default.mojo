# Must build, and is never run (scripts/check.sh builds it only). Evidence for
# docs/history/architecture-decisions.md, "Typed binary request body size
# limits decision (M3-043)": a required `max_bytes` makes a missing or
# misspelled limit a compile error only for a type that conforms to
# `FromBytes` directly. Under a refining trait that gives a family default,
# a misspelled override (`max_byte`) is an unrelated member Mojo 1.1.0
# accepts silently, and the type inherits the family's limit: here 16, not
# the 4096 the type meant. The route registers with that limit.
#
# If this file stops building, see which part failed. `Banner` no longer
# conforms (the misspelled member rejected): Mojo now checks member names
# against the traits, and the record's limited guarantee for refining traits
# can be widened. The assert fails (the value is no longer the family's):
# Mojo no longer inherits a refining trait's default, which breaks the
# family-default contract (docs/DX.md, `test_bytes_limit.mojo`'s refining
# trait test) and its advice. The registration rejected: re-read `_kind`'s
# handling of a limited type.
from muntin import App, FromBytes


trait SmallUpload(FromBytes):
    comptime max_bytes: Int = 16


struct Banner(SmallUpload):
    comptime max_byte = 4096  # the misspelled override
    var n: Int

    def __init__(out self, n: Int):
        self.n = n

    @staticmethod
    def from_bytes(body: List[UInt8]) raises -> Self:
        return Self(len(body))


def upload(banner: Banner) -> String:
    return String(banner.n)


def main():
    comptime assert Banner.max_bytes == 16, "the family default is inherited"
    var app = App()
    app.post["/banner"](upload)
