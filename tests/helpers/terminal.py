"""Run a command in a pseudo-terminal, standing in for Daniel's own terminal.

Usage: python3 -I terminal.py [--expect <text> --send <text>]... -- <command> [<args>...]
The command's stdin, stdout and stderr are the terminal. Each --send is typed once the output
since the previous one shows its --expect, in order; then the output is read to the end.
Prints everything the terminal showed, with \\r\\n as \\n, and exits as the command did, or 124
once the command hangs, naming on stderr the text it was still waiting for. A hang is 60 s with no
new output, or 10 minutes in all for one that keeps printing: it catches a command that stops or
loops, while a long run on a busy machine (tests/run runs the bats files in parallel) still ends.
"""

import os
import pty
import select
import signal
import sys
import time

USAGE = "usage: terminal.py [--expect <text> --send <text>]... -- <command> [<args>...]"


def main():
    args = sys.argv[1:]
    steps = []
    while args and args[0] != "--":
        if len(args) < 4 or args[0] != "--expect" or args[2] != "--send":
            sys.exit(USAGE)
        steps.append((args[1].encode(), args[3].encode()))
        args = args[4:]
    if len(args) < 2:
        sys.exit(USAGE)

    pid, fd = pty.fork()
    if pid == 0:
        try:
            os.execvp(args[1], args[1:])
        finally:
            os._exit(127)

    output, seen = b"", 0
    ceiling = time.monotonic() + 600
    deadline = min(time.monotonic() + 60, ceiling)
    while True:
        if steps:
            found = output.find(steps[0][0], seen)
            if found >= 0:
                seen = found + len(steps[0][0])
                os.write(fd, steps.pop(0)[1])
                continue
        left = deadline - time.monotonic()
        if left <= 0:
            os.kill(pid, signal.SIGKILL)
            os.waitpid(pid, 0)
            sys.stdout.write(output.replace(b"\r\n", b"\n").decode(errors="replace"))
            waiting = steps[0][0].decode() if steps else "the end of the output"
            why = "10 minutes in all" if deadline >= ceiling else "60 s with no output"
            print(f"terminal.py: gave up after {why} waiting for: {waiting}", file=sys.stderr)
            sys.exit(124)
        ready, _, _ = select.select([fd], [], [], left)
        if not ready:
            continue
        try:
            chunk = os.read(fd, 4096)
        except OSError:  # Linux: EIO once the command has closed the terminal
            break
        if not chunk:  # macOS: end of file
            break
        output += chunk
        deadline = min(time.monotonic() + 60, ceiling)

    _, status = os.waitpid(pid, 0)
    sys.stdout.write(output.replace(b"\r\n", b"\n").decode(errors="replace"))
    for expect, _ in steps:
        print(f"terminal.py: the command ended before showing: {expect.decode()}", file=sys.stderr)
    sys.exit(os.waitstatus_to_exitcode(status))


main()
