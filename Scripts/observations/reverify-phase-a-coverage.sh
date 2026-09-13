#!/usr/bin/env bash
# Re-check 2026-09-07-phase-a-was-already-done-and-invisible — EXCEPT that it no longer has a
# subject.
#
# The reading was taken by driving `QualificationTransport` over the release binary. That type was
# removed on 2026-09-13 with the rest of the qualification subsystem, so the probe this script
# writes can no longer compile.
#
# What the record measured is still true of the PRODUCT: 21 of 23 read-only operations answered
# with a verified semantic readback. That is a fact about the read surface, not about the gate, and
# it survives the gate's removal. What does NOT survive is any way to take the reading again
# through this path.
#
# Refusing is the point. A build failure here would read as "the coverage moved", and it is not
# the coverage that moved.
set -uo pipefail
echo "CANNOT-REVERIFY(3): QualificationTransport was removed on 2026-09-13 — the probe cannot be built."
exit 3
