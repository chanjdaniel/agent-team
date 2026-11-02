2. Review what changed since the last review, `git diff {{reviewed}} {{head}}`, and the commit messages of `origin/{{base}}..{{head}}`, on the builder's local branch.
   Under the plan's Disclosure section the builder pushes nothing until this review passes the branch's wording, so read every commit message, test name, comment and doc that diff adds or changes against that section of `{{plan}}`.
