#!/usr/bin/env python3
"""Deterministic LC_UUID normalization for reproducible release builds.

Swift/ld64 emits a per-link LC_UUID that is not reproducible across independent
clean builds. This tool rewrites that field to a content-derived value so two
independent clean builds of the same source produce a byte-identical, still
loadable, still ad-hoc-signable Mach-O.

Algorithm (deterministic): zero the 16-byte LC_UUID payload, compute
SHA-256 over the entire resulting Mach-O, and write the first 16 bytes of that
digest back into the LC_UUID payload. The input must be an unsigned, stripped
thin arm64 Mach-O (run after `codesign --remove-signature` and `strip -x`,
before re-signing).

Fail-closed guarantees, each verified (not assumed):
- refuses fat/universal, big-endian, non-64-bit, and non-arm64 images
- requires exactly one LC_UUID load command with a valid in-bounds 24-byte layout
- proves that only the 16 UUID payload bytes changed by comparing the patched
  image against the original outside the UUID window
- re-reads the file after writing and verifies it equals the patched image

Prints machine-readable provenance (JSON) to stdout on success.

Usage: reproducible-build-uuid-patch.py <mach-o-binary>
"""
import hashlib
import json
import struct
import sys

MH_MAGIC_64 = 0xFEEDFACF          # thin 64-bit, host-endian little
MH_CIGAM_64 = 0xCFFAEDFE
FAT_MAGIC = 0xCAFEBABE
FAT_CIGAM = 0xBEBAFECA
CPU_TYPE_ARM64 = 0x0100000C
LC_UUID = 0x1B
HDR_64_LEN = 32
UUID_CMDSIZE = 24


def die(msg: str) -> None:
    print("PATCH_FAIL: " + msg, file=sys.stderr)
    sys.exit(3)


def main() -> None:
    if len(sys.argv) != 2:
        die("usage: reproducible-build-uuid-patch.py <mach-o-binary>")
    path = sys.argv[1]
    with open(path, "rb") as fh:
        original = fh.read()
    data = bytearray(original)
    if len(data) < HDR_64_LEN:
        die("file too small to be a Mach-O")

    magic = struct.unpack_from("<I", data, 0)[0]
    if magic in (FAT_MAGIC, FAT_CIGAM):
        die("fat/universal binary not supported; expected thin arm64")
    if magic != MH_MAGIC_64:
        if magic == MH_CIGAM_64:
            die("big-endian Mach-O not supported")
        die("not a 64-bit Mach-O (magic=0x%08x)" % magic)

    cputype, _cpusub, _ftype, ncmds, sizeofcmds, _flags, _rsv = struct.unpack_from(
        "<iiIIIII", data, 4
    )
    if cputype != CPU_TYPE_ARM64:
        die("unexpected cputype 0x%08x; expected arm64 0x%08x" % (cputype, CPU_TYPE_ARM64))
    if ncmds == 0 or sizeofcmds == 0:
        die("no load commands")
    if HDR_64_LEN + sizeofcmds > len(data):
        die("load command region exceeds file size")

    # Walk load commands, collect every LC_UUID payload offset.
    uuid_offsets = []
    off = HDR_64_LEN
    end = HDR_64_LEN + sizeofcmds
    for _ in range(ncmds):
        if off + 8 > end:
            die("truncated load command table")
        cmd, cmdsize = struct.unpack_from("<II", data, off)
        if cmdsize < 8 or off + cmdsize > end:
            die("invalid load command size at offset %d" % off)
        if cmd == LC_UUID:
            if cmdsize != UUID_CMDSIZE:
                die("LC_UUID cmdsize %d != %d" % (cmdsize, UUID_CMDSIZE))
            payload = off + 8
            if payload + 16 > len(data):
                die("LC_UUID payload out of bounds")
            uuid_offsets.append(payload)
        off += cmdsize

    if len(uuid_offsets) != 1:
        die("expected exactly 1 LC_UUID, found %d" % len(uuid_offsets))
    uoff = uuid_offsets[0]

    before = original[uoff:uoff + 16]
    # Deterministic content-derived UUID.
    data[uoff:uoff + 16] = b"\x00" * 16
    input_digest = hashlib.sha256(bytes(data)).hexdigest()
    new_uuid = bytes.fromhex(input_digest)[:16]
    data[uoff:uoff + 16] = new_uuid
    patched = bytes(data)

    # Verified post-conditions (fail-closed):
    # 1. Nothing outside the 16-byte UUID window changed.
    if len(patched) != len(original):
        die("patched image size changed")
    if patched[:uoff] != original[:uoff] or patched[uoff + 16:] != original[uoff + 16:]:
        die("bytes outside the LC_UUID window changed")
    # 2. The UUID window now holds the derived value.
    if patched[uoff:uoff + 16] != new_uuid:
        die("LC_UUID window does not hold the derived value")

    with open(path, "wb") as fh:
        fh.write(patched)
    # 3. On-disk content equals the verified patched image.
    with open(path, "rb") as fh:
        if fh.read() != patched:
            die("post-write verification failed")

    print(json.dumps({
        "tool": "reproducible-build-uuid-patch.py",
        "uuid_offset": uoff,
        "algorithm": "sha256(mach-o with LC_UUID 16-byte payload zeroed)[:16]",
        "input_sha256_uuid_zeroed": input_digest,
        "uuid_before": before.hex(),
        "uuid_after": new_uuid.hex(),
        "bytes_changed_outside_uuid_window": 0,
    }))


if __name__ == "__main__":
    main()
