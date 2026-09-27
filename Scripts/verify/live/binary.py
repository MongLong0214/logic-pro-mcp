"""Build by construction: a binary is bound to a commit because this module built it from that commit.

Given a SHA, `build()`:

1. resolves it to a full commit in the repository (`git rev-parse --verify <sha>^{commit}`);
2. reuses a cached build only if the cache record's head equals the SHA AND the recorded sha256
   still equals a fresh hash of the file at the recorded path;
3. otherwise adds a detached worktree at `~/worktrees/logic-pro-mcp/.verify-build/<sha>` (never
   /tmp, which macOS empties at boot), refuses it if `git status --porcelain` is not empty, and runs
   `swift build -c release` with its whole output written to a log file -- never piped into `head`,
   whose SIGPIPE kills the build and leaves a half-stale product (reference_head_in_a_build_pipe_
   kills_the_build);
4. copies the product to `.verify-build/bin/LogicProMCP-<sha>-<sha256[:16]>`, a path that did not
   exist before, and hashes the copy. The binary is never run in place: an in-place relink can keep
   serving the old image (reference_running_the_built_binary_in_place_serves_a_stale_image);
5. removes the worktree, keeping the binary and a record `<sha>.json` beside it.

Returns {head, binary_path, binary_sha256, binding: "built-by-verifier", build_log_tail, ...raw}.
A failure returns `binary_path: None` with the stage and its raw output.
"""

import hashlib
import json
import os
import re
import shutil
import subprocess

from . import obs

BUILD_ROOT = os.path.expanduser("~/worktrees/logic-pro-mcp/.verify-build")
PRODUCT = "LogicProMCP"
BUILD_TIMEOUT_S = 3600
LOG_TAIL_LINES = 60
SHA_RE = re.compile(r"^[0-9a-f]{40}$")


def sha256_of(path):
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def record_path(sha, root=BUILD_ROOT):
    return os.path.join(root, "bin", f"{sha}.json")


def cached(sha, root=BUILD_ROOT):
    """The cache record for `sha` and whether it still describes the file. Raw either way."""
    path = record_path(sha, root)
    try:
        with open(path, "r", encoding="utf-8") as handle:
            record = json.load(handle)
    except FileNotFoundError:
        return {"record_path": path, "exists": False, "usable": False}
    except (OSError, ValueError) as exc:
        return {"record_path": path, "exists": True, "usable": False, "cause": repr(exc)}
    binary = record.get("binary_path")
    try:
        measured = sha256_of(binary) if binary else None
    except OSError as exc:
        measured, cause = None, repr(exc)
    else:
        cause = None
    usable = (record.get("head") == sha and bool(measured)
              and measured == record.get("binary_sha256"))
    return {"record_path": path, "exists": True, "record": record, "measured_sha256": measured,
            "measure_error": cause, "usable": usable}


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

    cache = cached(head, root)
    if cache["usable"]:
        record = cache["record"]
        return {**record, "cache": cache, "reused": True, "stages": stages}

    checkout = os.path.join(root, head)
    os.makedirs(os.path.join(root, "bin"), exist_ok=True)
    if os.path.exists(checkout):
        status = obs.run(["git", "-C", checkout, "status", "--porcelain"], 60)
        stages.append({"stage": "existing-checkout-status", **status})
        return {"head": head, "binary_path": None, "cache": cache, "stages": stages,
                "cause": ("a checkout already exists at the build path; refusing to reuse it "
                          "(dirty)" if (status.get("stdout") or "").strip() else
                          "a checkout already exists at the build path; refusing to reuse it")}

    added = obs.run(["git", "-C", repo, "worktree", "add", "--detach", checkout, head], 300)
    stages.append({"stage": "checkout", **added})
    if added["returncode"] != 0:
        return {"head": head, "binary_path": None, "cause": "git worktree add failed",
                "cache": cache, "stages": stages}
    try:
        return _build_in(head, checkout, root, timeout_s, stages, cache)
    finally:
        removed = obs.run(["git", "-C", repo, "worktree", "remove", "--force", checkout], 300)
        stages.append({"stage": "remove-checkout", **removed,
                       "exists_after": os.path.exists(checkout)})


def _build_in(head, checkout, root, timeout_s, stages, cache):
    status = obs.run(["git", "-C", checkout, "status", "--porcelain"], 60)
    at = obs.run(["git", "-C", checkout, "rev-parse", "HEAD"], 30)
    stages.append({"stage": "checkout-status", **status, "checkout_head": at.get("stdout", "").strip()})
    if status["returncode"] != 0 or (status.get("stdout") or "").strip():
        return {"head": head, "binary_path": None, "cause": "the checkout is dirty; refused",
                "cache": cache, "stages": stages}
    if at.get("stdout", "").strip() != head:
        return {"head": head, "binary_path": None, "cause": "the checkout is not at the SHA",
                "cache": cache, "stages": stages}

    log_path = os.path.join(root, "bin", f"{head}.build.log")
    started = obs.now()
    with open(log_path, "w", encoding="utf-8") as log:
        try:
            proc = subprocess.run(["swift", "build", "-c", "release"], cwd=checkout, stdout=log,
                                  stderr=subprocess.STDOUT, timeout=timeout_s)
            code, timed_out = proc.returncode, False
        except subprocess.TimeoutExpired:
            code, timed_out = None, True
    tail = _tail(log_path)
    stages.append({"stage": "swift-build", "returncode": code, "timed_out": timed_out,
                   "elapsed_s": obs.now() - started, "log_path": log_path})
    if code != 0:
        return {"head": head, "binary_path": None, "cause": "swift build -c release failed",
                "build_log_tail": tail, "cache": cache, "stages": stages}

    bin_dir = obs.run(["swift", "build", "-c", "release", "--show-bin-path"], 120, cwd=checkout)
    stages.append({"stage": "show-bin-path", **bin_dir})
    product = os.path.join((bin_dir.get("stdout") or "").strip(), PRODUCT)
    if bin_dir["returncode"] != 0 or not os.path.isfile(product):
        return {"head": head, "binary_path": None, "cause": "no product at the bin path",
                "product": product, "build_log_tail": tail, "cache": cache, "stages": stages}

    built_sha = sha256_of(product)
    dest = os.path.join(root, "bin", f"{PRODUCT}-{head}-{built_sha[:16]}")
    if os.path.exists(dest):
        existing = sha256_of(dest)
        stages.append({"stage": "copy", "dest_existed": True, "dest_sha256": existing})
        if existing != built_sha:
            return {"head": head, "binary_path": None, "cause": "a different file holds the path",
                    "cache": cache, "stages": stages}
    else:
        shutil.copy2(product, dest)
        stages.append({"stage": "copy", "dest_existed": False})
    copied_sha = sha256_of(dest)
    if copied_sha != built_sha:
        return {"head": head, "binary_path": None, "cause": "the copy does not hash as the build",
                "built_sha256": built_sha, "copied_sha256": copied_sha, "stages": stages}

    record = {"head": head, "binary_path": dest, "binary_sha256": copied_sha,
              "binding": "built-by-verifier", "build_log_tail": tail, "build_log": log_path,
              "product_in_checkout": product}
    with open(record_path(head, root), "w", encoding="utf-8") as handle:
        json.dump(record, handle, indent=1)
    return {**record, "cache": cache, "reused": False, "stages": stages}
