# Must build, and is never run (scripts/check.sh builds it only). Evidence for
# docs/history/architecture-decisions.md, "Typed binary request body size limits
# decision (M3-043)": the fail-open case of a refining trait's default. When a
# family's default is `Int.MAX`, a type that misspells its override (`max_byte`)
# compiles and is registered with no limit at all, the same outcome the required
# member closes for a type that conforms to `FromBytes` directly.
# docs/reference/bodies.md therefore advises a finite family default.
#
# If this file stops building: Mojo now checks member names against the
# traits, and the record's limited guarantee for refining traits can be
# widened.
from muntin import App, FromBytes


trait AnyUpload(FromBytes):
    comptime max_bytes: Int = Int.MAX


struct Archive(AnyUpload):
    comptime max_byte = 1024 * 1024  # the misspelled override
    var n: Int

    def __init__(out self, n: Int):
        self.n = n

    @staticmethod
    def from_bytes(body: List[UInt8]) raises -> Self:
        return Self(len(body))


def upload(archive: Archive) -> String:
    return String(archive.n)


def main():
    comptime assert Archive.max_bytes == Int.MAX, "no limit is inherited"
    var app = App()
    app.post["/archive"](upload)
