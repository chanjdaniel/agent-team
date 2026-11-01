# 06: A project's standing review rules in one file

Phase 1.

**What to build:** the reviewer, rereview and verify templates include `{{> review-rules}}`, which `team-brief` fills with the team home's `projects/<project>/review-rules.md` before it reads placeholders, or with nothing when the file is absent, as the spec's "Briefs" says.

**Blocked by:** 05

**Waits for:** T171 merged (the reviewer templates).

**Files:** `bin/team-brief`, `templates/briefs/reviewer.md`, `templates/briefs/rereview.md`, `templates/briefs/verify.md`, `tests/team-brief.bats`, `roles/coordinator.md` (one line saying where the rules live).

- [ ] With a fixture rules file holding `{{head}}`, a rendered reviewer, rereview and verify brief each holds the rules with the head filled in.
- [ ] With no file, each renders as it does on `dev`, but for the empty line it leaves out.
- [ ] A rules file with an unknown placeholder is refused naming it, as any template is.
- [ ] The delivery partials (`{{> delivery}}`, `{{> review}}`, `{{> rereview}}`) still come from `templates/briefs/<name>/<delivery>.md`.
- [ ] `team-brief --help` names the file and says it is the coordinator's records.
- [ ] `tests/run` passes.
