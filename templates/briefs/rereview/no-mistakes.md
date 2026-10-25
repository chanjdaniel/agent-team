2. Review what changed since the last review, `git diff {{reviewed}} {{head}}`, and the commit messages of `origin/{{base}}..{{head}}`.
   That diff holds the gate's own commits, which no reviewer has read: read them as closely as the builder's, and the PR body the gate wrote; after the gate's first run, `{{reviewed}}` is the branch's local head, reviewed before the gate.
   If the gate rebased the branch, so `{{reviewed}}` is not an ancestor of `{{head}}`, compare with `git range-diff {{reviewed}}...{{head}}` instead.
