#!/usr/bin/env python3
"""Runs a command on a real pty and reports what a terminal would show.

WHY THIS EXISTS
---------------
The hidden-token prompt can only be trusted if it is exercised on a real
terminal. The `script(1)` utility is a poor driver for that: it copies its own
stdin into the pty master and demonstrably drops bytes mid-paste, it injects an
EOF byte when its stdin closes, and it gives no way to observe the line
discipline. This harness drives the pty directly with `pty.fork()`, so the child
gets a genuine controlling terminal, and it reads the SLAVE's termios from the
parent side — which is how the two properties that actually broke on 2026-10-11
become measurable:

  * echo is really disabled while the prompt is up (the value cannot be seen),
  * echo/icanon/isig are really restored afterwards, including when the child is
    killed while it waits (that regression left three terminals silently
    swallowing everything typed).

Usage (all options optional):
  pty_prompt_probe.py [--send TEXT] [--send-delay SEC] [--send-after PROMPT]
                      [--signal SIG] [--signal-delay SEC] [--max-wait SEC]
                      [--expect-exit N] -- command [args...]

Output (key=value lines, plus the transcript on stdout delimited by markers):
  exit=<status>            child exit status (-N for signal N)
  elapsed=<seconds>        wall clock of the whole run
  echo_at_prompt=on|off    ECHO bit while the child was at the prompt
  echo_after=on|off        ECHO bit after the child exited
  modes_restored=yes|no    ECHO|ICANON|ISIG identical before and after
  transcript_has_send=yes|no   whether the sent text was echoed back
"""

import argparse
import errno
import os
import pty
import re
import select
import signal
import sys
import termios
import time

# The modes the prompt is allowed to touch, and must give back.
MODES = termios.ECHO | termios.ICANON | termios.ISIG


def lflag(fd):
    try:
        return termios.tcgetattr(fd)[3]
    except termios.error:
        return None


def main():
    parser = argparse.ArgumentParser(add_help=True)
    parser.add_argument("--send", default=None)
    parser.add_argument("--press-enter", action="store_true",
                        help="append a carriage return to --send (a real Enter key)")
    parser.add_argument("--send-delay", type=float, default=0.0)
    parser.add_argument("--send-after", default=None,
                        help="wait for this text in the output before sending")
    parser.add_argument("--signal", default=None)
    parser.add_argument("--signal-delay", type=float, default=0.0)
    parser.add_argument("--max-wait", type=float, default=30.0)
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()

    command = args.command
    if command and command[0] == "--":
        command = command[1:]
    if not command:
        print("usage: pty_prompt_probe.py [options] -- command [args...]", file=sys.stderr)
        return 2

    start = time.time()
    pid, master = pty.fork()
    if pid == 0:                                  # child: a real terminal session
        try:
            os.execvp(command[0], command)
        except OSError as exc:
            os.write(2, f"exec failed: {exc}\n".encode())
            os._exit(127)

    before_modes = lflag(master) & MODES if lflag(master) is not None else None
    transcript = bytearray()
    sent = False
    prompted_modes = None
    sent_at = None
    signal_sent = False
    deadline = start + args.max_wait

    while True:
        now = time.time()
        if now >= deadline:
            try:
                os.kill(pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            break

        # Send the configured text exactly once, either when the prompt has
        # appeared (--send-after) or after a fixed delay (--send-delay).
        if args.send is not None and not sent:
            if args.send_after is not None:
                due = args.send_after.encode() in bytes(transcript)
            else:
                due = now - start >= args.send_delay
            if due:
                payload = args.send.encode()
                if args.press_enter:
                    payload += b"\r"          # the byte a terminal sends for Enter
                os.write(master, payload)
                sent = True
                sent_at = now
        if args.signal and not signal_sent and now - start >= args.signal_delay:
            try:
                os.kill(pid, getattr(signal, args.signal))
            except ProcessLookupError:
                pass
            signal_sent = True

        # capture output
        try:
            ready, _, _ = select.select([master], [], [], 0.05)
        except InterruptedError:
            continue
        if ready:
            try:
                chunk = os.read(master, 65536)
            except OSError as exc:
                if exc.errno == errno.EIO:          # slave closed: child is done
                    break
                raise
            if not chunk:
                break
            transcript += chunk

        # observe the line discipline while the child is at the prompt
        if prompted_modes is None and b"access_token:" in bytes(transcript):
            prompted_modes = lflag(master)

    try:
        _, status = os.waitpid(pid, 0)
    except ChildProcessError:
        status = 0
    # Read the slave's modes from the master BEFORE closing it: the pty still
    # exists while we hold the master, so this is the state the child left
    # behind — the whole point of the check.
    after = lflag(master)
    os.close(master)
    elapsed = time.time() - start
    text = bytes(transcript)
    exit_status = os.waitstatus_to_exitcode(status) if hasattr(os, "waitstatus_to_exitcode") else (
        -os.WTERMSIG(status) if os.WIFSIGNALED(status) else os.WEXITSTATUS(status))

    def bit(value, flag):
        return "unknown" if value is None else ("on" if value & flag else "off")

    print(f"exit={exit_status}")
    print(f"elapsed={elapsed:.1f}")
    print(f"echo_at_prompt={bit(prompted_modes, termios.ECHO)}")
    print(f"echo_after={bit(after, termios.ECHO)}")
    print(f"modes_restored={'yes' if (before_modes is not None and after is not None and (before_modes & MODES) == (after & MODES)) else 'no'}")
    if args.send:
        tail = text.split(b"access_token:", 1)[-1]
        print(f"transcript_has_send={'yes' if args.send.strip().encode() in tail else 'no'}")
    print("---- transcript ----")
    sys.stdout.write(re.sub(r"\r\n", "\n", text.decode("utf-8", "replace")))
    print("---- end ----")
    return 0


if __name__ == "__main__":
    sys.exit(main())
