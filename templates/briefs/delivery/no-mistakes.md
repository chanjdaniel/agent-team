## Deliver through no-mistakes

1. Run `/no-mistakes` with this intent: "{{task}}: {{goal}}"
2. The PR must target `{{base}}`; if the gate opens it against another branch, retarget it to `{{base}}` and close any duplicate.
3. When the gate returns checks-passed, send `{{task}} PR <full url>` to `coordinator`.
