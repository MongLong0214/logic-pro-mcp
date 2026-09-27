"""Build by construction: a binary is bound to a commit because this module built it from that commit.

Given a SHA, `build()`:

1. resolves it to a full commit in the repository (`git rev-parse --verify <sha>^{commit}`);
2. adds a detached worktree at `~/worktrees/logic-pro-mcp/.verify-build/<sha>` (never
   /tmp, which macOS empties at boot), refuses it if `git status --porcelain` is not empty, and runs
   `swift build -c release` with its whole output written to a log file -- never piped into `head`,
   whose SIGPIPE kills the build and leaves a half-stale product (reference_head_in_a_build_pipe_
   kills_the_build);
3. copies the product to `.verify-build/bin/LogicProMCP-<sha>-<sha256[:16]>-<run>`, a path that did
   not exist before, and hashes the copy. The binary is never run in place: an in-place relink can keep
   serving the old image (reference_running_the_built_binary_in_place_serves_a_stale_image);
4. removes the worktree, keeping the binary.

Nothing on disk is ever read back as a build (PR #1033 review R2): a record claiming a head and a
hash certifies only itself, so `binding: "built-by-verifier"` is returned only by the call that ran
`swift build` in this process. `Builds` reuses a head's result in memory within one run.

Returns {head, binary_path, binary_sha256, binding: "built-by-verifier", build_log_tail, ...raw}.
A failure returns `binary_path: None` with the stage and its raw output.
"""

import hashlib
import os
import re
import shutil
import subprocess
import time

from . import obs

BUILD_ROOT = os.path.expanduser("~/worktrees/logic-pro-mcp/.verify-build")
PRODUCT = "LogicProMCP"
BUILD_TIMEOUT_S = 3600
LOG_TAIL_LINES = 60
SHA_RE = re.compile(r"^[0-9a-f]{40}$")
SWIFT_BUILD = ["swift", "build", "-c", "release"]


def sha256_of(path):
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _tail(path, lines=LOG_TAIL_LINES):
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as handle:
            return handle.read().splitlines()[-lines:]
    except OSError as exc:
        return [f"<log unreadable: {exc!r}>"]


def build(sha, repo, root=BUILD_ROOT, timeout_s=BUILD_TIMEOUT_S):
    """Build `sha` from `repo` by construction. See the module docstring."""
    stages = []
    resolved = obs.run(["git", "-C", repo, "rev-parse", "--verify", f"{sha}^{{commit}}"], 30)
    stages.append({"stage": "resolve", **resolved})
    head = (resolved.get("stdout") or "").strip()
    if resolved["returncode"] != 0 or not SHA_RE.match(head):
        return {"head": None, "binary_path": None, "cause": "the SHA does not name a commit",
                "stages": stages}

    checkout = os.path.join(root, head)
    os.makedirs(os.path.join(root, "bin"), exist_ok=True)
    if os.path.exists(checkout):
        status = obs.run(["git", "-C", checkout, "status", "--porcelain"], 60)
        stages.append({"stage": "existing-checkout-status", **status})
        return {"head": head, "binary_path": None, "stages": stages,
                "cause": ("a checkout already exists at the build path; refusing to reuse it "
                          "(dirty)" if (status.get("stdout") or "").strip() else
                          "a checkout already exists at the build path; refusing to reuse it")}

    added = obs.run(["git", "-C", repo, "worktree", "add", "--detach", checkout, head], 300)
    stages.append({"stage": "checkout", **added})
    if added["returncode"] != 0:
        return {"head": head, "binary_path": None, "cause": "git worktree add failed",
                "stages": stages}
    try:
        return _build_in(head, checkout, root, timeout_s, stages)
    finally:
        removed = obs.run(["git", "-C", repo, "worktree", "remove", "--force", checkout], 300)
        stages.append({"stage": "remove-checkout", **removed,
                       "exists_after": os.path.exists(checkout)})


def _build_in(head, checkout, root, timeout_s, stages):
    status = obs.run(["git", "-C", checkout, "status", "--porcelain"], 60)
    at = obs.run(["git", "-C", checkout, "rev-parse", "HEAD"], 30)
    stages.append({"stage": "checkout-status", **status, "checkout_head": at.get("stdout", "").strip()})
    if status["returncode"] != 0 or (status.get("stdout") or "").strip():
        return {"head": head, "binary_path": None, "cause": "the checkout is dirty; refused",
                "stages": stages}
    if at.get("stdout", "").strip() != head:
        return {"head": head, "binary_path": None, "cause": "the checkout is not at the SHA",
                "stages": stages}

    run_id = f"{os.getpid()}-{time.time_ns()}"
    log_path = os.path.join(root, "bin", f"{head}-{run_id}.build.log")
    started = obs.now()
    with open(log_path, "w", encoding="utf-8") as log:
        try:
            proc = subprocess.run(SWIFT_BUILD, cwd=checkout, stdout=log,
                                  stderr=subprocess.STDOUT, timeout=timeout_s)
            code, timed_out = proc.returncode, False
        except subprocess.TimeoutExpired:
            code, timed_out = None, True
    tail = _tail(log_path)
    stages.append({"stage": "swift-build", "returncode": code, "timed_out": timed_out,
                   "elapsed_s": obs.now() - started, "log_path": log_path})
    if code != 0:
        return {"head": head, "binary_path": None, "cause": "swift build -c release failed",
                "build_log_tail": tail, "stages": stages}

    bin_dir = obs.run(SWIFT_BUILD + ["--show-bin-path"], 120, cwd=checkout)
    stages.append({"stage": "show-bin-path", **bin_dir})
    product = os.path.join((bin_dir.get("stdout") or "").strip(), PRODUCT)
    if bin_dir["returncode"] != 0 or not os.path.isfile(product):
        return {"head": head, "binary_path": None, "cause": "no product at the bin path",
                "product": product, "build_log_tail": tail, "stages": stages}

    built_sha = sha256_of(product)
    dest = os.path.join(root, "bin", f"{PRODUCT}-{head}-{built_sha[:16]}-{run_id}")
    if os.path.exists(dest):
        return {"head": head, "binary_path": None, "cause": "the run's own path already exists",
                "stages": stages}
    shutil.copy2(product, dest)
    stages.append({"stage": "copy", "dest": dest})
    copied_sha = sha256_of(dest)
    if copied_sha != built_sha:
        return {"head": head, "binary_path": None, "cause": "the copy does not hash as the build",
                "built_sha256": built_sha, "copied_sha256": copied_sha, "stages": stages}
    return {"head": head, "binary_path": dest, "binary_sha256": copied_sha,
            "binding": "built-by-verifier", "build_log_tail": tail, "build_log": log_path,
            "product_in_checkout": product, "stages": stages}


class Builds:
    """One run's builds: each head is built once by this process and reused only from memory."""

    def __init__(self, repo, root=BUILD_ROOT, timeout_s=BUILD_TIMEOUT_S):
        self.repo, self.root, self.timeout_s = repo, root, timeout_s
        self._built = {}

    def get(self, sha):
        if sha in self._built:
            return {**self._built[sha], "reused_in_run": True}
        result = build(sha, self.repo, self.root, self.timeout_s)
        if result.get("binary_path"):
            self._built[sha] = result
        return result
