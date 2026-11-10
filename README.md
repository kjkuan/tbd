[![CI](https://github.com/kjkuan/tbd/actions/workflows/ci.yml/badge.svg)](https://github.com/kjkuan/tbd/actions/workflows/ci.yml)

## What is it?
_TBD_ (Tmux Bash Debugger) is a simple debugger for Bash that can be used to
interactively inspect or debug the execution of a Bash script. It's meant to be
`source`'ed into your script at the place where you want a break point to be set.
Once at the break point, _TBD_ will take over and run in a separate _tmux_ window,
from which you can interact and explore the execution environment of the script.

> **NOTE:** _TBD_ temporarily `set +eu` for the duration of a debugging session.

_TBD_ uses separate _tmux_ windows as debugging REPLs; one for the script's
process, and one for each subshell created by the script. This not only leaves
the script's terminal alone for direct user interactions, but it also makes it
possible to debug a shell pipeline, which could have multiple subshells running
as parallel processes.

Multiple and conditional break points are possible by sourcing _TBD_ multiple
times in the script. Setting conditional break points at runtime is also possible
with the caveat that a break point set from a subshell on its parent process will
have no effects.

See the [examples/fizzbuzz](examples/fizzbuzz) script and `/help` for details, and
try finding the two bugs in [examples/restock](examples/restock) with _TBD_:

```bash
DEBUG=1 examples/restock
```

Check out the demo, which does just that (spoilers!):

[![asciicast](https://asciinema.org/a/B2HrHb46Qc4ryjSk.svg)](https://asciinema.org/a/B2HrHb46Qc4ryjSk)


## Prerequisites
_TBD_ needs Bash 4.4 or later (on macOS, which ships Bash 3.2, install a newer
one; e.g., `brew install bash`).

You need to be running in a _tmux_ session already, and have [bat], `less`,
and [tmux] in `PATH`. Of course, you should know how to use _tmux_; at least,
you should know how to switch between _tmux_ windows.

The [headless mode](#headless-mode-for-ai-agents-and-programs) needs none of
these, just Bash (4.4 or later).

[bat]: https://github.com/sharkdp/bat
[tmux]: https://github.com/tmux/tmux


## Installation and Usage
Currently, there's no automatic installation; just clone the repo, and add `tbd.sh`,
`tbd-view`, `tbd-headless`, and `tbd-ctl` somewhere in `PATH`. For example:

```bash
git clone git@github.com:kjkuan/tbd.git
cd tbd && PATH=$PWD:$PATH
```

To use it, simply `source tbd.sh` somewhere in your script, and run your script from
a _tmux_ window; follow the on-screen help, or enter `/help`, for instructions.
See also the [demo] above.

[demo]: https://asciinema.org/a/B2HrHb46Qc4ryjSk


## Headless Mode (for AI Agents and Programs)
`tbd-ctl` drives _TBD_ without _tmux_ or a terminal: each command returns
promptly with plain-text results, which makes it easy for an AI agent (or any
program) to step through a script and inspect its state, instead of adding
`echo`s and re-running it. For example:

```console
$ tbd-ctl run -s examples/restock    # -s: stop at the first command, even if
Session: /tmp/tbd-ctl.mOoj1C2W       #     the script doesn't source tbd.sh
Script: examples/restock (pid 4100)

[4102] stopped at /home/me/tbd/examples/restock:10 in restock (last exit status: 0); next command:
    set -e

$ tbd-ctl send 4102 '/set-break 38 [[ $sku == banana ]]'
[4102] stopped at /home/me/tbd/examples/restock:10 in restock (last exit status: 0); next command:
    set -e

$ tbd-ctl resume 4102
[4102] running
[4121] stopped at /home/me/tbd/examples/restock:38 in main() (last exit status: 0); next command:
    cost=$(restock_cost "$qty" "$price")

$ tbd-ctl send 4121 'echo "$sku $qty $price"'
banana 7 0.25

[4102] running
[4121] stopped at /home/me/tbd/examples/restock:38 in main() (last exit status: 0); next command:
    cost=$(restock_cost "$qty" "$price")

$ tbd-ctl end
Killed the script (pid 4100).
Ended the session.
```

Each process, including each subshell (e.g., a side of a pipeline), is debugged
separately, identified by its PID. See `tbd-ctl --help` for all the commands.
It's also how to point an AI agent at it: tell it to read `tbd-ctl --help`.

Under the hood, setting `TBD_HEADLESS` to a directory makes `tbd.sh` start
`tbd-headless`, instead of `tbd-view`, which keeps the debugger's state in files
under that directory, and takes commands from a FIFO there.


## Running Tests
The tests are end-to-end specs written with [ShellSpec]; they drive _TBD_ in
isolated, detached _tmux_ servers, so they don't touch your _tmux_ session, though
they still need `tmux`, `bat`, and `less` in `PATH`. To run them:

```bash
shellspec
```

Set `TBD_TIMEOUT` (in seconds, default 15) to change how long a spec waits for
the debugger before failing.

[ShellSpec]: https://github.com/shellspec/shellspec
