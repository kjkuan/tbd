## What is it?
**TBD** (Tiny Bash Debugger) is a simple debugger for Bash that can be used to
interactively inspect or debug the execution of a Bash script. It's meant to be
`source`ed into your script at the place where you want a break point to be set.
Once at the break point, **TBD** will take over and run in a separate `tmux` window,
from which you can interact with the script.


## Prerequisites
You need to be running in a `tmux` session already, and have `bat`, `less`,
and `tmux` in `PATH`.


## Installation and Usage
Currently, there's no automatic installation; just put `tbd.sh` and `tbd-view` somewhere
in `PATH` and make both executable. To use it, simply `source tbd.sh` somewhere in
your script, and run your script from a `tmux` window.
