2. Review what changed since the last review, `git diff {{reviewed}} {{head}}`, and the commit messages of `origin/{{base}}..{{head}}`; the gate has not run yet, so the diff holds the builder's commits only.
   When `{{plan}}` has a Disclosure section, read every commit message, test name, comment and doc that diff adds or changes against it.
