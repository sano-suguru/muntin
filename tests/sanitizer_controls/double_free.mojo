# AddressSanitizer positive control (PR #97): restores ownership of one
# allocation twice, as a doubly run `__deinit__` in _handler_storage.mojo
# would. `SANITIZE=address ./scripts/test.sh` requires this binary to fail
# with the report below.
# Expected report: AddressSanitizer: attempting double-free

from std.memory import OwnedPointer


@no_inline
def release(addr: Int):
    var raw = OwnedPointer(0).unsafe_take_allocation().unsafe_leak()
    _ = OwnedPointer[Int](unsafe_from_raw_pointer=raw)
    raw = type_of(raw)(unsafe_from_address=addr)
    _ = OwnedPointer[Int](unsafe_from_raw_pointer=raw)


def main():
    var raw = OwnedPointer(7).unsafe_take_allocation().unsafe_leak()
    print(raw[])
    release(Int(raw))
    release(Int(raw))
