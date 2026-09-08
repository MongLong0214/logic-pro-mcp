# What a dev ticket has to contain before anyone implements it

A ticket is finished when the person implementing it needs **no judgement**. Not "little" — none.
Every judgement left in a ticket is a decision made by whoever happens to pick it up, at the moment
they are least equipped to make it, and it will not be recorded anywhere.

This standard exists because the failure has a shape here. Two examples from one working period:

- A ticket was drafted for #302 R2 on the roadmap's reading that the Event List exposes six columns.
  The reading was accurate and accurately transcribed; **what it was about** was wrong — those six
  are the region-level schema, and the note level has eight. The ticket was withdrawn before any
  code, and had it been implemented it would have re-written working code against another pane's
  schema.
- A design question was posed as "reshape the identity, or go and measure the Event List". The
  answer was neither: the four fields are a descriptor and become an identity only through a
  binding. A ticket written from either of the two options offered would have been wrong.

Both were caught by checking the premise, not by the ticket being well written. A ticket that is
specific enough makes the premise checkable.

## Required, and a ticket without these is a draft

**1. The measurement the ticket rests on, with its limits.**
Quote the reading. Name the host, the date, the fixture. Say which of the ticket's claims would
change if the reading turned out to be about something else. If the ticket rests on a reading
nobody took, say so — "not measured" is a legitimate entry and an unstated assumption is not.

**2. Exact file paths, and for a change to existing code, the exact before and after.**
Not "update the identity type". The current declaration, verbatim, and the one that replaces it.
Anyone reading the ticket should be able to produce the diff without opening the file to decide
anything; opening it to *check* is expected.

**3. Every call site the change reaches, enumerated.**
Counted, listed, and each one classified: mechanical substitution, needs a value the ticket
supplies, or cannot be resolved mechanically. The third class is where the judgement is, so the
ticket has to make the decision there rather than leaving it.

**4. Acceptance criteria that can fail.**
Each one a statement about observable behaviour with a way to check it. "The boundary is preserved"
is not a criterion. "A consumer that constructs the identity from raw fields does not compile, and
the check uses ordinary consumer access rather than `@testable`" is.

**5. The mutations that must turn a test RED.**
Written as a list of specific edits to the production code and, for each, which test goes red.
A ticket whose tests all pass on an unchanged tree has not been shown to test anything: this list
is how the implementer proves the tests they wrote can fail.

**6. Not in scope, explicitly.**
The neighbouring work that will look like it belongs and does not. Without this the ticket grows
during implementation and the growth is invisible in review.

**7. What the ticket does NOT establish.**
Carried forward into the work and into the commit. A ticket that reads as though everything is
settled produces an implementation that claims more than it measured.

## Sizing

State the size and the reason in the same sentence. "L because production observation, proof
provenance, observation lifetime and consumer migration; the six test constructors are the small
part" is a size. "L" is not.

If the honest answer is that the measurements do not establish the work is possible, the ticket
says that, and **ending in a refusal rather than an implementation is a legitimate outcome**. A
ticket that cannot fail is the same defect as a test that cannot fail.

## Who writes what

The judgement in a ticket — the contract, the trade-off, the refusal boundary — belongs to whoever
is deciding it, and the reasoning goes in the ticket rather than in a conversation. The
implementation belongs to whoever can follow the ticket. That split only works when the ticket
carries the judgement; a thin ticket silently moves the decision to the implementer.
