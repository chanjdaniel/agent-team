"""command-guard's delete rows: a recursive delete that reaches what is not the worker's own.

bin/lib/command_rules.py appends ROWS to its table after the kill rows (bin/lib/kill_rules.py).
Each row is its id, its test over one command_text.Command and the call's context, returning its
reason when it refuses and None when it passes, and its allowed way, as kill_rules.py's are.
It holds no row yet.
"""

# The rows, in order: each its id, its test and its allowed way.
ROWS = ()
