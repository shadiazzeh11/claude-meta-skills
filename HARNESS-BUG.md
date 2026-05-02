**Title:** Plan mode triggers on user-space Skill tool invocations but not on bundled/plugin skills (Claude Code 2.1.126)

## Summary

When the assistant invokes the `Skill` tool with a user-space skill (defined under `~/.claude/skills/`), the harness automatically attaches `plan_mode` reminders to the conversation, putting the session into Plan Mode. The same `Skill` tool invocation against a bundled or plugin-sourced skill does not trigger this behavior. The trigger appears to depend on skill source location, not skill content or frontmatter.

## Environment

- Claude Code version: `2.1.126`
- Platform: macOS (Darwin 25.3.0)
- User-space skill structure: `~/.claude/skills/<name>/SKILL.md` with minimal frontmatter (`name`, `description` only — no `mode` field, no workflow directives)
- No hooks configured: `~/.claude/settings.json` and `~/.claude/settings.local.json` contain no `hooks` key
- No plan-mode references in any user-space or plugin file (verified via `grep -r "EnterPlanMode\|plan_mode\|planMode" ~/.claude/skills/ ~/.claude/plugins/ ~/.claude/settings*` — returns only incidental text matches in an unrelated, non-enabled `code-modernization` plugin)

## Reproduction

1. Create a user-space skill at `~/.claude/skills/<name>/SKILL.md` with valid frontmatter (`name`, `description`) and any body content.
2. In a session that started in `default` permission mode, have the assistant invoke `Skill(<name>)`.
3. Observe: `attachment` records with `"type":"plan_mode"` and `"reminderType":"full"` are inserted into the session log immediately after the assistant's `Skill` tool call. The assistant receives `<system-reminder>` blocks asserting "Plan mode is active. The user indicated that they do not want you to execute yet" — even though the user did not enter plan mode.

## Controlled test (the diagnostic that narrowed the trigger)

Same session, same permission mode (`default`), single difference (skill source location):

- `Skill(verification-before-recommend)` — user-space (`~/.claude/skills/verification-before-recommend/SKILL.md`) → plan mode triggered. Two `attachment` records with `"type":"plan_mode"` appended to session log within milliseconds of the tool call.
- `Skill(keybindings-help)` — bundled (not in `~/.claude/skills/`, not in `~/.claude/plugins/marketplaces/...`) → plan mode did NOT trigger. Zero new `plan_mode` attachments after the call.

Session log evidence (from `~/.claude/projects/<project>/<session-id>.jsonl`):

```
Line 1:   {"type":"permission-mode","permissionMode":"default","sessionId":"..."}
Line 26:  <assistant message containing Skill(verification-before-recommend)>
Line 27:  {"attachment":{"type":"plan_mode","reminderType":"full",
            "planFilePath":"/Users/.../misty-foraging-barto.md","planExists":false},
            "timestamp":"2026-05-02T03:05:28.243Z","version":"2.1.126"}
Line 29:  <duplicate plan_mode attachment, milliseconds apart>

[later in same session, after manually exiting plan mode]
<assistant message containing Skill(keybindings-help)>
<NO plan_mode attachment in session log following this call>
```

Total `"type":"plan_mode"` attachment count in session log: 2 (both from the user-space skill invocation; zero added by the bundled-skill invocation).

## Ruled out as causes (read-only investigation)

- SKILL.md frontmatter (contained only `name` and `description` — no `mode` field, no workflow flags)
- SKILL.md body content (no `EnterPlanMode`, `plan_mode`, or workflow directive present; grep confirmed)
- `~/.claude/settings.json` and `~/.claude/settings.local.json` (no `hooks` key in either; settings.json contains only `enabledPlugins` and `extraKnownMarketplaces`)
- Plugin-installed hooks (only enabled plugin is `skill-creator@claude-plugins-official`; its `plugin.json` contains only `name`, `description`, `author` — no `hooks` key)
- Pre-existing plan-mode session state (line 1 of session log proves session started in `default` permission mode)

## Observed behavior

- Plan mode is entered without any user action (no shift+tab, no slash command, no `EnterPlanMode` invocation by the assistant).
- The `<system-reminder>` text asserts "The user indicated that they do not want you to execute yet" — which is incorrect; the user invoked the assistant normally and never requested plan mode.
- The plan-mode reminder constrains the assistant from running non-readonly tools, requires the assistant to write a plan file, and forces the turn to end with `AskUserQuestion` or `ExitPlanMode`.
- The user must manually exit plan mode (e.g., via shift+tab) before normal operation resumes.

## Expected behavior

Either:

1. Skill tool invocations should not enter plan mode based on skill source location alone, OR
2. If user-space skills are intentionally treated differently for safety or other reasons, this is currently undocumented in the Skill tool's description, and the harness `<system-reminder>` text inaccurately attributes the plan-mode entry to user action.

## Impact

For reference-style skills (those whose purpose is to apply a discipline in-prose, e.g., a verification or simplification skill), forcing plan mode breaks the intended interaction model. The Skill tool's documented "BLOCKING REQUIREMENT to invoke" guidance collides with this trigger: invoking the skill as instructed leaves the assistant unable to apply the discipline because plan mode constraints prevent the in-response actions the discipline calls for.

## Workaround

Rely on the skill's description in the system-reminder skills list (and any backstop content in `~/.claude/CLAUDE.md`) to keep the discipline reachable in-prose; skip the Skill tool invocation. Works, but bypasses the documented invocation pathway and limits the skill's ability to compose with other tools the discipline might need to call.
