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

See the [examples/fizzbuzz](examples/fizzbuzz) script and `/help` for details.

Check out the demo [![asciicast](https://asciinema.org/a/btQpdrIcFKJuqgsARFvp7LEXY.svg)](https://asciinema.org/a/btQpdrIcFKJuqgsARFvp7LEXY)


## Prerequisites
You need to be running in a _tmux_ session already, and have [bat], `less`,
and [tmux] in `PATH`. Of course, you should know how to use _tmux_; at least,
you should know how to switch between _tmux_ windows.

[bat]: https://github.com/sharkdp/bat
[tmux]: https://github.com/tmux/tmux


## Installation and Usage
Currently, there's no automatic installation; just clone the repo, add `tbd.sh` and `tbd-view`
somewhere in `PATH`, and make both executable. For example:

```bash
git clone git@github.com:kjkuan/tbd.git
cd tbd && PATH=$PWD:$PATH
```

To use it, simply `source tbd.sh` somewhere in your script, and run your script from
a _tmux_ window; follow the on-screen help, or enter `/help`, for instructions.
See also the [demo] above.

[demo]: https://asciinema.org/a/btQpdrIcFKJuqgsARFvp7LEXY
