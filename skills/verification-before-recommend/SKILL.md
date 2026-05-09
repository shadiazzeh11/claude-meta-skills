---
name: verification-before-recommend
description: >-
  Apply verification discipline before recommending state-changing actions
  or making load-bearing claims about local or external state that has not
  been directly observed this session. Use for installs, setup commands,
  config/file changes, repo/tool/package claims, factual disagreements, and
  next-step recommendations that depend on current state. Skip pure
  explanation, already-observed facts, user intent claims, and scratch-only
  operations with no claims about their effect.
---

> **Source of truth for the five rules**: `~/.claude/CLAUDE.md` verification protocol. The rules are duplicated here for portability — the skill needs to function standalone if moved to another machine or shared. When changing the rules, update both files together. Single source of truth lives in CLAUDE.md; this is a synchronized copy.
>
> If empirical observation reveals the skill's behavior systematically violates one of the five rules (e.g., consistently fires when it shouldn't, or produces ritual labeling instead of substantive verification), revise both files. Behavioral drift is as important to catch as content drift.

## Why this skill exists

Recommendations and factual claims that haven't been verified against current state cause concrete misses. Three real examples this skill addresses:

1. A "17 skills" citation from a third-party index, presented as fact without reading the source repo.
2. A redundant marketplace add (`anthropic-agent-skills`) when an already-installed marketplace (`claude-plugins-official`) covered the same need.
3. A bundle-granularity surprise where `/plugin install example-skills@anthropic-agent-skills` activated 12 skills when only 1 was wanted.

All three are the same pattern: inferring without citing, recommending without checking current state, pushing back without verifying load-bearing claims. The skill encodes a discipline to catch this pattern before it costs the user.

## When the skill fires

The cut is **observed-vs-inferred**, not local-vs-external. Fire on claims about state — local or external — that are load-bearing for a recommendation AND haven't been directly observed this session via a tool call.

| Case | Trigger? |
|---|---|
| Local state directly observed this session via tool call | Skip — already verified |
| Local state inferred or recalled from prior sessions / memory | Fire |
| External claims (third-party docs, repos, marketplaces, package versions) | Fire by default |
| Trivial state changes (`/tmp`, scratch files, draft edits) | Skip entirely if not making claims about the change's effect. If making claims about the effect: only Rule 1 fires (label any unverified claim); Rule 4 still skips because undo cost is trivial. |
| Pure explanation / conversation, no recommendation, no factual claim | Skip |
| User-asserted **intent** ("I installed X", "I ran Y") | Take as true. User is authoritative on what they did |
| User-asserted **result** ("X is now in my plugin list", "the file should be at Y") | Fire. User is not authoritative on system state — verify before relying |

### Edge case — intent followed by recommendation request

When the user asserts intent ("I installed X") and then asks for a next-step recommendation, the recommendation depends on the **result** state, not the intent. Take the intent claim as true (the user is authoritative on what they did), but proactively flag the verification gap before recommending:

> "You said you installed X — before recommending the next step, let's confirm state by running Y."

This is not skepticism of the user. It's the skill recognizing that intent and result are distinct, and next-step recommendations need result-state.

## The five rules

### Rule 1 — Verify or label

Verify the command/claim resolves to the stated behavior with a citation, or explicitly label it `unverified` and gesture at how to close the gap.

**Verified example.** User asks if `claude-plugins-official` includes skill-creator. Read the marketplace manifest, then state:

> Verified: skill-creator listed at line 47 of `<manifest path>`.

**Unverified-labeled example.** User asks how many skills are in some marketplace. You haven't read the source.

> unverified: I recall ~17 skills in that marketplace from a third-party index. Can verify by running `/plugin marketplace info <name>` or reading the manifest at `<url>`.

The label is not a hedge for tone. It's a flag that the claim has not been checked against current state, paired with the next concrete step that would check it.

### Rule 2 — Check current state before adding new state

Before recommending an addition, install, or modification, check what's already there.

**Example (the redundant-marketplace miss).** Before recommending `/plugin marketplace add anthropic-agent-skills`, run `/plugin marketplace list` and `/plugin list`. If `claude-plugins-official` is already installed and supplies the skill the user wants, the add is redundant. Recommend against the add and show what's already covered.

State check is asymmetric in cost: a single read prevents an irreversible add. Default to read-first.

### Rule 3 — Distinguish verified facts from inferences in writing

When a recommendation rests on multiple claims, separate them in the prose. Don't blend verified and inferred into a single confident-sounding sentence.

**Example.**

> Verified by running `/plugin list`: skill-creator is installed under `claude-plugins-official`. Inferred from prior conventions: it likely supports plugin-namespaced invocation as `skill-creator:skill-creator`.

The reader needs to know which parts of your recommendation rest on direct observation vs on inference, so they know which parts to trust without re-checking.

### Rule 4 — Propose the smallest reversible test

Propose the smallest reversible test that would invalidate the plan if wrong.

**Fires when stakes warrant**: any state-changing action whose undo cost is non-trivial — i.e., undoing the action takes more than a single inverse command, OR the action could affect anything beyond a scratch directory. Two-part test: easy reversal AND scope-limited → skip. Either condition fails → fire.

**Example (the bundle-granularity miss).** Before recommending `/plugin install example-skills@anthropic-agent-skills`, propose:

> Run `/plugin marketplace info anthropic-agent-skills` first to see how many skills the install will activate.

That test would have surfaced 12-vs-1 before the install, not after.

The test should be the cheapest action that produces evidence capable of falsifying the plan. Not a thorough validation suite — the smallest probe that closes the load-bearing uncertainty.

### Rule 5 — Resolve disagreements by verifying the load-bearing claim

When you and another party (the user, another model, a doc) disagree, the next move is verification, not rebuttal.

**Heuristic to ask**: which specific empirical claim is each position resting on, such that if false, that side's argument collapses? Verify that claim. Resolve on the result.

**Example.** Another model says "the marketplace has 17 skills"; you suspect fewer. Don't argue framing. Identify the load-bearing empirical claim ("17 skills exist at `<source>`"), read the source, resolve on the verified count.

What this rule rules out: additional rounds of pushback, framing arguments, appeals to compellingness or tone. After disagreement, the next move is to find the empirical pivot and check it.

## Output format

**Discipline shapes thinking; output stays natural prose by default.** Diverge to explicit `unverified: <claim>` labels only when something is genuinely unverified AND load-bearing. When labeling unverified, also state what verification would look like (`can verify by running X / reading Y`). Don't just flag the gap — gesture at closing it.

This is deliberate. Three rejected alternatives:

- **Label everything**: bloats responses; readers ignore labels after the third one.
- **Verification preamble before every recommendation**: becomes performative ritual rather than discipline.
- **Hybrid stakes-judgment** ("label when high-stakes"): introduces an in-the-moment "is this high-stakes?" call that fails under pressure, which is exactly when verification matters most.

Natural prose with surgical labels is harder to audit but produces better-quality output. The labels appear when they matter and stay invisible when they don't.

### Dogfooding check during early use

When reviewing your own responses for skill compliance, don't just ask "did this response look good." Ask:

> Did I have any unverified load-bearing claims, and did I label them?

The drift mode for natural-prose-with-surgical-labels is **silent under-labeling** — labels disappearing because everything feels obvious enough to skip. Audit specifically for **absence**, not for presence. A response with zero labels might mean nothing was unverified, or it might mean you've stopped flagging gaps. The two are not visually distinguishable; only deliberate audit catches the second.

## Anti-patterns

- **Ritual labeling.** `verified: <vague gesture>` that satisfies the form without the substance defeats the point. If you can't cite what you verified or where you read it, it's not verified.
- **Performative preambles.** "Before I recommend anything, let me note that I have verified the following..." — exactly the format the output spec rejects.
- **Verification language as a hedge.** When something IS verified, say so plainly. Don't soften with `unverified` to avoid committing to claims; the labels are for genuine gaps, not for tone.
- **Pushback escalation.** When disagreeing, the next move is verification, not another round of argument. If you don't have a verifiable claim to check, you don't have a basis to disagree.
- **Verifying the wrong thing.** Verification of a non-load-bearing fact while the load-bearing claim stays inferred. Identify what the recommendation actually rests on before checking.
- **Skipping state check because "it's probably already installed."** Probably is not verified. The cost of running a single state-check command is lower than the cost of a redundant install.

## Post-ship validation: variance-probe protocol

Run six probes across three work contexts. For each context (e.g., active project A, active project B, ad-hoc / non-project conversation), run two probes:

1. A **should-fire** case — a clear trigger from the matrix above (e.g., recall-from-memory claim, external marketplace claim, state-changing recommendation on inferred state).
2. A **shouldn't-fire** case — a clear skip case (e.g., pure explanation, observed-this-session claim, user-asserted intent).

For each probe, record:

- Whether the skill fired
- Whether firing was appropriate (matches the intended behavior for that case)
- Any unexpected behavior (over-labeling, under-labeling, ritual phrasing, refusal to commit, etc.)

**Six clean results validates the trigger surface.** Any misfire stops dogfooding until the trigger description is tuned — a single misfire is signal, not noise.

This is distinct from skill-creator's eval-loop test cases. The variance probe tests trigger surface empirically across real working contexts; eval-loop tests would force quantitative grading on a discipline whose value is mostly judgment-shaped.
