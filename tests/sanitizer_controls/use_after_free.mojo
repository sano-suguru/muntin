# AddressSanitizer positive control (PR #97): reads an allocation after
# freeing it, through the ownership operations _handler_storage.mojo uses.
# `SANITIZE=address ./scripts/test.sh` requires this binary to fail with
# the report below; if it passes, the sanitizer no longer sees the error.
# Expected report: AddressSanitizer: heap-use-after-free

from std.memory import OwnedPointer


def main():
    var values: List[Int] = [1, 2, 3]
    var raw = OwnedPointer(values^).unsafe_take_allocation().unsafe_leak()
    _ = OwnedPointer[List[Int]](unsafe_from_raw_pointer=raw)
    print(len(raw[]))
