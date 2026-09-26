#!/usr/bin/env python3
"""The advisory Canon note on an issue: at most one, owned by this workflow, updated in place.

WHAT WAS WRONG WITH THE SHELL VERSION

It ran the checker, captured stdout and stderr together, and pasted the result under a fixed
sentence saying the issue "states something about Logic without citing Logic's own data". Three
separate things came out of that one sentence:

  * A missing declaration was reported as an established semantic claim about the issue.
  * A corpus that would not load reached the author as the same accusation.
  * Every edit took the create-comment path, so a conversation collected notes and a body that
    was repaired was still standing under a warning nobody withdrew.

This reads the checker's `--format json` result -- the same evaluation the pull request gate uses,
not a second citation engine -- and turns a CATEGORY into wording that matches it. It is advisory
throughout: it never closes, locks, labels or blocks anything, and a tooling failure is reported
as this repository's failure.

WHAT MAKES A NOTE OURS

The marker below, AND the identity of the account that wrote it. A marker alone is a string
anybody can paste: a contributor who copies one into their own comment must not thereby hand this
workflow permission to rewrite what they wrote. Both have to agree, on every page of the comment
list.
"""

import json
import os
import subprocess
import sys
import tempfile

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CHECKER = os.path.join(REPO, "Scripts", "check-canon-citations.py")

MARKER = "<!-- logic-pro-mcp:canon-guidance:v1 -->"

#: The state is part of the rendered body so that a run which changes nothing writes nothing.
#: Anything that varies per run -- a timestamp, a run id -- would make every run an edit, and a
#: note that edits itself on a schedule is a note people mute.
ACTIONABLE, RESOLVED, UNKNOWN, SUPERSEDED = "actionable", "resolved", "unknown", "superseded"

#: CONTRIBUTING.md rather than `docs/canon/README.md`: the README is the design of the axis and
#: runs to four hundred lines, and a contributor who has just been told something is missing wants
#: the two paragraphs that say what to write. The anchor is GitHub's slug for the `## Citing
#: Logic's own data` heading, and `test_the_documentation_link_resolves` checks both still exist.
DOC_PATH = "CONTRIBUTING.md"
DOC_ANCHOR = "#citing-logics-own-data"
DOC_LINK = f"https://github.com/MongLong0214/logic-pro-mcp/blob/main/{DOC_PATH}{DOC_ANCHOR}"

#: Bounds on anything copied out of the body. Long enough to name the problem, short enough that
#: an issue does not become a corpus dump.
MESSAGE_LIMIT = 400
MESSAGE_COUNT = 5

HEADINGS = {
    "missing_declaration":
        "This issue does not yet carry a usable citation, or an explicit declaration that the "
        "evidence requirement does not apply to it.",
    "hidden_declaration":
        "The declaration is there, but only inside a code block or an HTML comment. Those are "
        "deliberately not read -- a sentence that renders as an example is not a declaration -- "
        "so moving it into ordinary prose is the whole fix.",
    "declaration_quotes_corpus":
        "This issue declares that it states no fact about Logic, and also quotes a string Logic "
        "ships. Cite that string instead of declaring it away.",
    "invalid_reference":
        "A reference here does not resolve against the committed index.",
    "missing_quoted_value":
        "A reference here appears without the value it resolves to. The citation is the "
        "reference AND the value, so a reader can see what was claimed.",
    "unrelated_binding":
        "The references here resolve, but none of them bears on what this is about.",
    "logic_facing_opt_out":
        "This declares that it states no fact about Logic, but it touches files whose contents "
        "are claims about Logic.",
    "unproved_exceptions":
        "The Logic-facing exception list is not proved, which is a repository-side problem "
        "rather than anything about this issue.",
    "empty_changed_list":
        "The list of changed files was empty, so nothing could be derived from it.",
}

#: What the note says when this workflow could not evaluate. It makes no claim about the issue.
COULD_NOT_EVALUATE = (
    "Canon guidance: this check could not evaluate the issue body. That is a problem in this "
    "repository's tooling, not a statement about this issue or its author. Nothing here is "
    "being asserted about what the issue claims; a maintainer will look at the workflow log.")


def sanitize(text: str, limit: int = MESSAGE_LIMIT) -> str:
    """Text copied out of the body, made safe to render and bounded.

    An issue body is attacker-controlled, and a comment is a rendering surface. `@` becomes a full
    width form so a copied handle cannot notify a person or an organisation who has nothing to do
    with this, and backticks cannot close the fence this is rendered inside.
    """
    folded = text.replace("`", "'").replace("@", "＠")
    if len(folded) > limit:
        folded = folded[:limit].rstrip() + " [...]"
    return folded


def render(category: str, findings: list, body_label: str = "") -> str:
    """The comment body for one evaluation. Identical input renders identically, byte for byte."""
    if category == "error":
        return "\n".join([MARKER, _state(UNKNOWN), "", COULD_NOT_EVALUATE])

    if category == "satisfied":
        return "\n".join([
            MARKER, _state(RESOLVED), "",
            "Canon guidance: the earlier evidence-format note is resolved for the body as it now "
            "stands. This says nothing about whether the issue's report is correct, whether any "
            "described behaviour was reproduced, or whether anything here has been implemented "
            "-- only that the citation or declaration requirement is satisfied by this text.",
        ])

    lines = [MARKER, _state(ACTIONABLE), ""]
    codes = [code for code, _ in findings]
    lead = next((HEADINGS[code] for code in codes if code in HEADINGS),
                HEADINGS["missing_declaration"])
    lines.append(f"Canon guidance: {lead}")
    lines.append("")
    lines.append(
        "You can submit and discuss this issue either way -- nothing is blocked and nothing is "
        "being closed. Add the evidence when you have it, or use the documented declaration with "
        f"a reason if this makes no claim about Logic. A maintainer can help map an observation "
        f"to the corpus; you do not need the corpus build to report a problem. "
        f"[What this means]({DOC_LINK})")

    detail = "\n".join(sanitize(_relabel(message, body_label))
                       for _, message in findings[:MESSAGE_COUNT])
    if detail.strip():
        lines += ["", "<details><summary>What the check reported</summary>", "",
                  "```", detail, "```", "", "</details>"]
    return "\n".join(lines)


def _relabel(message: str, body_label: str) -> str:
    """The checker names its input by path. In a comment that path is noise from a runner."""
    if body_label and message.startswith(f"{body_label}:"):
        return "issue body:" + message[len(body_label) + 1:]
    return message


def _state(state: str) -> str:
    return f"<!-- logic-pro-mcp:canon-guidance-state:{state} -->"


def state_of(body: str):
    """The managed state a comment declares, or None when it is not a managed note at all."""
    if MARKER not in body:
        return None
    for state in (ACTIONABLE, RESOLVED, UNKNOWN, SUPERSEDED):
        if _state(state) in body:
            return state
    return None


#: The whole note the workflow before #959 posted, minus the checker output it pasted between
#: these two halves. It carried no marker, so a body repaired after it never withdrew it and a
#: body edited again got a second one. Matched exactly, and only from the bot's own account: a
#: contributor quoting that text keeps their comment, as with the marker.
LEGACY_HEAD = (
    "This issue states something about Logic without citing Logic's own data, or\n"
    "cites it in a form that does not resolve. See `docs/canon/README.md`.\n\n```\n")
LEGACY_TAIL = (
    "\n```\n\nNothing is blocked -- an issue has no merge to stop. This is a note for whoever\n"
    "triages it.\n")


def _ours(comment: dict, expected_login: str) -> bool:
    user = comment.get("user") or {}
    return user.get("login") == expected_login and user.get("type") == "Bot"


def owned(comment: dict, expected_login: str) -> bool:
    """Whether this workflow wrote that comment.

    BOTH the marker and the identity. The marker says what the comment is for; the identity says
    who wrote it. A contributor who pastes the marker into their own comment keeps their comment.
    """
    if not _ours(comment, expected_login):
        return False
    return state_of(comment.get("body") or "") is not None


def legacy(comment: dict, expected_login: str) -> bool:
    """Whether this is an unmarked note the workflow before #959 wrote, in its exact format."""
    if not _ours(comment, expected_login):
        return False
    body = comment.get("body") or ""
    return (MARKER not in body and body.startswith(LEGACY_HEAD) and body.endswith(LEGACY_TAIL)
            and len(body) >= len(LEGACY_HEAD) + len(LEGACY_TAIL))


def decide(category: str, rendered: str, note):
    """What to do about the one managed note: ("none"|"create"|"edit", why).

    The transitions are #951's table. Two of them are the point of the whole change: a run that
    changes nothing writes nothing, and a run that could not evaluate never marks anything
    resolved -- an unknown result must not be able to withdraw a warning it did not re-examine.
    """
    if note is None:
        if category == "satisfied":
            return "none", "nothing to resolve and nothing to say"
        if category == "error":
            return "none", "could not evaluate, and an accusation is not the fallback"
        return "create", "first guidance note for this issue"

    if (note.get("body") or "") == rendered:
        return "none", "the note already says exactly this"
    if state_of(note.get("body") or "") is None:
        return "edit", f"the pre-#959 note is adopted and moves to {state_of(rendered)}"
    return "edit", f"the note moves to {state_of(rendered)}"


class GitHub:
    """`gh` calls, kept behind one seam so the decisions above can be tested without a network."""

    def __init__(self, repo: str):
        self.repo = repo

    #: Pages of comments this will read before giving up. A bound rather than a while-true: an
    #: endpoint that never shortens a page would otherwise spin.
    MAX_PAGES = 100
    PER_PAGE = 100

    def _api(self, path: str, method: str = "GET", fields=None):
        args = ["gh", "api", "-H", "Accept: application/vnd.github+json"]
        if method != "GET":
            args += ["--method", method]
        for key, value in (fields or {}).items():
            args += ["-f", f"{key}={value}"]
        args.append(path)
        done = subprocess.run(args, capture_output=True, text=True)
        if done.returncode != 0:
            raise RuntimeError(f"gh api {path} failed: {done.stderr.strip()[:500]}")
        return done.stdout

    def issue_body(self, number: int) -> str:
        return json.loads(self._api(f"repos/{self.repo}/issues/{number}")).get("body") or ""

    def comments(self, number: int) -> list:
        """Every comment, on every page. A managed note can be past the first.

        Paged by hand rather than with `gh api --paginate`, which concatenates the pages into one
        stream of JSON arrays: splitting that back apart means scanning text a comment body can
        contain. Each page is parsed on its own, and a short page ends the walk.
        """
        out: list = []
        for page in range(1, self.MAX_PAGES + 1):
            chunk = json.loads(self._api(
                f"repos/{self.repo}/issues/{number}/comments"
                f"?per_page={self.PER_PAGE}&page={page}"))
            out.extend(chunk)
            if len(chunk) < self.PER_PAGE:
                return out
        raise RuntimeError(f"issue {number} has more than {self.MAX_PAGES} pages of comments; "
                           f"a managed note beyond that would be invisible, so this refuses "
                           f"rather than writing a second one")

    def create_comment(self, number: int, body: str) -> dict:
        return json.loads(self._api(f"repos/{self.repo}/issues/{number}/comments",
                                    method="POST", fields={"body": body}))

    def update_comment(self, comment_id: int, body: str) -> dict:
        return json.loads(self._api(f"repos/{self.repo}/issues/comments/{comment_id}",
                                    method="PATCH", fields={"body": body}))


#: The checker's exit status and the category it printed are two halves of one contract, and this
#: is the reading side of it. `check-canon-citations.py` owns `EXIT_FOR`; a status this does not
#: name -- 2 from a crashed interpreter, a negative number from a signal -- is an evaluation that
#: did not finish, whatever the process managed to print before it stopped.
EXPECTED_STATUS = {0: "satisfied", 1: "actionable", 2: "error"}

#: The checker reads one body and a committed index, which takes about a second. A run past this
#: is wedged rather than slow, and a wedged child holds a workflow job until the job's own limit.
CHECKER_TIMEOUT_SECONDS = 180


def _did_not_finish(path: str, why: str, stderr: str) -> dict:
    """The result shape for an evaluation that did not happen. It says nothing about the body."""
    return {"category": "error", "label": path,
            "diagnostics": [{"code": "checker_error", "message": why}],
            "stderr": stderr}


def _validated(done) -> dict:
    """The checker's own result, or ValueError naming what was wrong with it.

    `json.loads` alone was not enough. Its output is JSON in exactly the shape this expects only
    when it finished: `[]` is valid JSON and made `result.get` raise `AttributeError` out of the
    workflow, `{"category": "satisfied"}` with the process dead on a signal was read as a pass,
    and a diagnostic whose `message` is a number reached `sanitize` as one. Every one of those is
    an evaluation that did not happen being reported as one that did.
    """
    if done.returncode not in EXPECTED_STATUS:
        raise ValueError(f"the checker exited {done.returncode}, which is not one of "
                         f"{sorted(EXPECTED_STATUS)}")
    result = json.loads(done.stdout)
    if not isinstance(result, dict):
        raise ValueError(f"the result is {type(result).__name__}, not an object")
    category = result.get("category")
    if category not in EXPECTED_STATUS.values():
        raise ValueError(f"unknown category {category!r}")
    if EXPECTED_STATUS[done.returncode] != category:
        # Not pedantry: the status is what a wedged or killed process cannot fake, and the
        # category is what the note is worded from. Disagreement means one of them is not the
        # checker's answer, and there is no way to tell which.
        raise ValueError(f"the checker exited {done.returncode} and printed category "
                         f"{category!r}, which do not agree")
    diagnostics = result.get("diagnostics")
    if not isinstance(diagnostics, list):
        raise ValueError(f"diagnostics is {type(diagnostics).__name__}, not a list")
    for entry in diagnostics:
        if not isinstance(entry, dict):
            raise ValueError(f"a diagnostic is {type(entry).__name__}, not an object")
        for field in ("code", "message"):
            if not isinstance(entry.get(field), str):
                raise ValueError(f"a diagnostic's {field} is "
                                 f"{type(entry.get(field)).__name__}, not a string")
    if category == "actionable" and not diagnostics:
        # The heading is chosen FROM the diagnostics and falls back to "no usable citation" when
        # there are none. An actionable verdict carrying no finding would word that fallback into
        # a note about somebody's issue with nothing behind it.
        raise ValueError("an actionable result carried no diagnostics")
    return result


def evaluate(body: str) -> dict:
    """Ask the pull request gate's own checker about this text. Never a second implementation."""
    workdir = tempfile.mkdtemp(prefix="canon-issue-")
    path = os.path.join(workdir, "issue-body.md")
    with open(path, "w", encoding="utf-8") as handle:
        handle.write(body)
    try:
        done = subprocess.run([sys.executable, CHECKER, "--text", path, "--format", "json"],
                              capture_output=True, text=True, cwd=REPO,
                              timeout=CHECKER_TIMEOUT_SECONDS)
    except subprocess.TimeoutExpired:
        return _did_not_finish(
            path, f"the checker did not finish within {CHECKER_TIMEOUT_SECONDS}s", "")
    except OSError as exc:
        return _did_not_finish(path, f"the checker could not be run: "
                                     f"{type(exc).__name__}: {exc}", "")
    try:
        result = _validated(done)
    except (json.JSONDecodeError, ValueError) as exc:
        return _did_not_finish(path, f"the checker produced no usable result: {exc}", done.stderr)
    result["label"] = path
    result["stderr"] = done.stderr
    return result


def active_note(comments: list, expected_login: str):
    """The one note this workflow treats as current, and the owned notes it supersedes.

    Deterministic by comment id, so two runs that race pick the same one. Unowned comments are
    never touched, and an owned note already marked superseded is left alone -- otherwise this
    would rewrite the same comments on every run.

    A pre-#959 note is a candidate too, after every managed one: an issue that already has a
    managed note keeps it and the old notes are superseded, and an issue with only old notes has
    its oldest adopted. Otherwise a repaired body left the old warning standing and a failing edit
    added a managed note beside it.
    """
    ours = sorted((c for c in comments if owned(c, expected_login)), key=lambda c: c["id"])
    live = [c for c in ours if state_of(c["body"]) != SUPERSEDED]
    live += sorted((c for c in comments if legacy(c, expected_login)), key=lambda c: c["id"])
    if not live:
        return None, []
    return live[0], live[1:]


def one_line(text: str) -> str:
    """A maintainer-facing string, folded so it cannot open a workflow command of its own.

    `::name::` at the start of a line is how a runner reads a command, so a diagnostic carrying a
    newline could make the log claim whatever it liked. Folded rather than escaped: this is a
    breadcrumb pointing at the log, not the diagnostic itself.
    """
    return " ".join(text.split()).replace("::", ":")


def body_moved(api, number: int, body: str) -> bool:
    """Whether the body has changed since this evaluation read it.

    Asked again immediately before every write. The first check happened before the comment list
    was fetched, and fetching it is the slowest thing this does -- a hundred pages of an API on a
    busy issue -- so a repair landing during that walk still had the old actionable verdict
    published over it. The edit that changed the body has its own run, and that run supersedes
    this one; there is nothing to publish here.
    """
    if api.issue_body(number) == body:
        return False
    print("::notice::the issue body changed while this ran; its own run will report on it")
    return True


def main() -> int:
    repo = os.environ["GITHUB_REPOSITORY"]
    number = int(os.environ["ISSUE_NUMBER"])
    # The account this workflow's token comments AS. Not `github.actor`, which is whoever opened
    # the issue: confusing the two is how a bot ends up editing a contributor's comment.
    expected_login = os.environ.get("CANON_BOT_LOGIN", "github-actions[bot]")
    api = GitHub(repo)

    body = api.issue_body(number)
    result = evaluate(body)
    if result.get("stderr"):
        print(result["stderr"], file=sys.stderr)

    # The body may have been repaired while this ran. Publishing now would put an old warning over
    # a newer body; the edit that changed it has its own run, and that run supersedes this one.
    if body_moved(api, number, body):
        return 0

    findings = [(entry["code"], entry["message"]) for entry in result.get("diagnostics", [])]
    rendered = render(result["category"], findings, result.get("label", ""))

    comments = api.comments(number)
    note, extra = active_note(comments, expected_login)
    action, why = decide(result["category"], rendered, note)
    print(f"category={result['category']} action={action} ({why})")

    if result["category"] == "error":
        # The note tells the author nothing, by design. This line is the maintainer's half: the
        # cause, folded to one line, so the run that failed can be told from the run that did not.
        cause = "; ".join(entry["message"] for entry in result.get("diagnostics", []))
        print(f"::warning::the Canon check could not evaluate this issue body: "
              f"{one_line(sanitize(cause))} -- see the log above")

    # Asked again here, after the comment walk, because that walk is where the time goes.
    if action in ("create", "edit") and body_moved(api, number, body):
        return 0

    if action == "create":
        api.create_comment(number, rendered)
    elif action == "edit":
        try:
            api.update_comment(note["id"], rendered)
        except RuntimeError as exc:
            # One bounded recovery for a note deleted between listing and writing. Not a loop, and
            # never a fresh comment on an error -- that is how a conversation fills with notes.
            print(f"::warning::updating the managed note failed: {exc}", file=sys.stderr)
            note, extra = active_note(api.comments(number), expected_login)
            if note is None:
                return 1
            # And again: the recovery re-listed the comments, which is another round trip, and a
            # verdict that was stale before the first write is no fresher on the second.
            if body_moved(api, number, body):
                return 0
            api.update_comment(note["id"], rendered)

    for duplicate in extra:
        # A race left more than one owned note. Mark the losers once, which is idempotent: the
        # next run sees `superseded` and leaves them alone.
        api.update_comment(duplicate["id"], "\n".join(
            [MARKER, _state(SUPERSEDED), "",
             "Superseded by the current Canon guidance note on this issue."]))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
