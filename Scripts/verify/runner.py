"""P0b: the live lifecycle of the fixed verifier (ADR-027 D2, D5). Interfaces only, in this commit set.

Everything here raises NotImplementedError. The signatures are the contract P0b implements, and
`verify.py run` / `verify.py batch` call into them once they exist. What P0b owes, per ADR-027:

  * The binary is BUILT BY THE VERIFIER from a clean detached checkout of the exact head, and its
    sha256 is measured from the file it built. Only then is `binding` "built-by-verifier"; the
    engine treats anything else as never clean.
  * Observations are stored whole through `evidence_doc.make_observation(step, raw_text)`, or as
    `evidence_doc.unreadable_observation(step, reason)` when a read fails. A runner never stores a
    default in place of a reading and never stores a pass flag: it has none to store.
  * Verdicts come from `engine.evaluate_run(spec, run, locale)`, which is what `verdicts[locale]`
    holds, and the process exit is `engine.judge(doc)["exit"]`.
  * The lifecycle is sampled per step, not per run: screen lock, a modal or open menu (layer > 0),
    and server exclusivity (no second server holding the MCU ports). A step taken while one of
    those is dirty is stored as unreadable with that reason.
  * `batch` switches each locale once and runs every queued head's rows in it (D5): N features
    cost ten switches.
"""
from __future__ import annotations


class Session:
    """One MCP server process started from the verifier-built binary, exclusive for the run."""

    def call(self, tool: str, command: str, params: dict) -> str:
        """The tools/call reply as the exact JSON text received."""
        raise NotImplementedError("P0b")

    def read(self, uri: str) -> str:
        """The resources/read contents as the exact JSON text received."""
        raise NotImplementedError("P0b")

    def close(self) -> None:
        raise NotImplementedError("P0b")


def build_binary(head: str, workdir: str) -> dict:
    """Build LogicProMCP from a clean detached checkout of `head` (40 hex) under `workdir`.

    Returns the evidence `binary` block, keyed by the names in evidence_doc (BINARY_PATH,
    BINARY_SHA256, HEAD, BINDING): {"binary_path", "binary_sha256", "head",
    "binding": "built-by-verifier", "note"}. The engine re-hashes the file at binary_path when it
    judges, so the file must still exist when the evidence is rechecked on this host.
    """
    raise NotImplementedError("P0b")


def start_session(binary_path: str, env: dict) -> Session:
    """Start the server; refuse if another server already holds the MCU ports."""
    raise NotImplementedError("P0b")


def switch_locale(locale: str) -> dict:
    """Quit Logic, set its AppleLanguages to `locale` (one of engine.ALL_LOCALES), relaunch, and
    return Scripts/observation_host.py's host block measured afterwards. The run also stores
    Scripts/verify/live/locale.py reading(locale) under runs.<locale>.locale_reading; the engine
    refuses a run whose reading names another locale."""
    raise NotImplementedError("P0b")


def open_fixture(fixture: dict) -> None:
    """Open or reset the project named by the spec's `fixture.id` to its as-found state."""
    raise NotImplementedError("P0b")


def lifecycle_problems() -> list:
    """Why the machine is not clean for the next step right now (screen locked, modal, menu open);
    empty when it is."""
    raise NotImplementedError("P0b")


def execute_step(session: Session, step: dict) -> dict:
    """Run one step (call, read, probe or bounded wait) and return its observation entry."""
    raise NotImplementedError("P0b")


def run_spec(spec: dict, spec_path: str, head: str, locales: list, out_path: str) -> int:
    """Build, then for each locale: switch, open the fixture, run every row's steps and restore
    steps, store the observations, compute verdicts with the engine, write the evidence document
    atomically, and return engine.judge(doc)["exit"]."""
    raise NotImplementedError("P0b")


def run_batch(queue_path: str, out_dir: str) -> int:
    """Run every queued (spec, head) pair, switching each locale once for all of them."""
    raise NotImplementedError("P0b")
