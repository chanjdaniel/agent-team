# 06: A project's standing review rules in one file

Phase 1.

**What to build:** the reviewer, rereview and verify templates include `{{> review-rules}}`, which `team-brief` fills with the team home's `projects/<project>/review-rules.md` before it reads placeholders, or with nothing when the file is absent, as the spec's "Briefs" says.

**Blocked by:** 05

**Waits for:** T171 merged (the reviewer templates).

**Files:** `bin/team-brief`, `templates/briefs/reviewer.md`, `templates/briefs/rereview.md`, `templates/briefs/verify.md`, `tests/team-brief.bats`, `roles/coordinator.md` (one line saying where the rules live).

- [x] With a fixture rules file holding `{{head}}`, a rendered reviewer, rereview and verify brief each holds the rules with the head filled in.
- [x] With no file, each renders as it does on `dev`, but for the empty line it leaves out.
- [x] A rules file with an unknown placeholder is refused naming it, as any template is.
- [x] The delivery partials (`{{> delivery}}`, `{{> review}}`, `{{> rereview}}`) still come from `templates/briefs/<name>/<delivery>.md`.
- [x] `team-brief --help` names the file and says it is the coordinator's records.
- [x] `tests/run` passes (1583 bats tests, the toolkit tests and shellcheck, 6m 05s).

## Found along the way

- "But for the empty line it leaves out" is read as: with no rules file (or an empty one) the `{{> review-rules}}` line is dropped whole, so each brief renders exactly as on `dev`; the existing exact-text tests of the reviewer and verify briefs still pass unchanged.
- `roles/coordinator.md` is at its 120-line cap, so the rules' home is named inside step 5's first sentence, not on a line of its own.
