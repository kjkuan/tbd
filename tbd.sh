#!/usr/bin/env bash

[[ ! "$(trap -p DEBUG)" ]] || return 0

# If we're loaded via BASH_ENV (e.g., by `tbd-ctl run -s`), don't let it
# load TBD into other Bash processes started by the script.
if [[ ${BASH_ENV:-} && ${BASH_ENV:-} -ef ${BASH_SOURCE[0]} ]]; then
    unset BASH_ENV
    TBD_VIA_BASH_ENV=x
fi

# In headless mode (see tbd-headless and tbd-ctl), TBD_HEADLESS is the
# directory to keep the debugging session's state in; no tmux needed.
if [[ ${TBD_HEADLESS:-} ]]; then
    [[ $TBD_HEADLESS == /* ]] || TBD_HEADLESS=$PWD/$TBD_HEADLESS
    TBD_NO_COLOR=x
else
    { { which batcat || which bat; } && which less tmux; } >/dev/null 2>&1 || {
        echo "Please make sure 'bat' / 'batcat', 'less', and 'tmux' are in PATH!"
        exit 1
    } >&2

    # NOTE: Not a `bat` function, which would be visible to the script.
    if which batcat >/dev/null 2>&1; then TBD_BAT=batcat; else TBD_BAT=bat; fi

    [[ ${TMUX:-} ]] || {
        echo "Please run TBD within a tmux session."
        exit 1
    } >&2
    TBD_NO_COLOR=${NO_COLOR:-}
fi

TBD_ORIG_SET=${-/i}
TBD_ORIG_PWD=${TBD_ORIG_PWD:-$PWD}
set +eu

# Sourcing tbd.sh is a break point; stop at the next command even if we
# were resuming (e.g., a /resume in this process, or in its parent).
TBD_RESUMING=

# NOTE: The script being debugged might have changed IFS, so avoid relying
# on word splitting in any code that runs in the script's context.

if [[ $TBD_NO_COLOR ]]; then TBD_BAT_COLOR=never; else TBD_BAT_COLOR=always; fi

if [[ ! $TBD_NO_COLOR ]]; then
    TBD_NC='\e[0m'
    TBD_LIGHTRED='\e[1;31m'
    TBD_LIGHTGREEN='\e[1;32m'
    TBD_LIGHTBLUE='\e[1;34m'
    TBD_PROMPT_COLOR=${TBD_PROMPT_COLOR:-${TBD_LIGHTBLUE:-}}
fi


tbd-show-help () {
    "$TBD_BAT" --decorations never  \
        --italic-text always \
        --color "$TBD_BAT_COLOR" \
        -l markdown <<'EOF'
Welcome to _TBD_, the Tmux Bash Debugger!

The `?` is the debugger prompt. `(N)` at the beginning of the prompt is the exit
status of the previous command before entering the `DEBUG` trap. The line above it
is the current command (not executed yet) the debugger is stepping on. What happens
next depends on what you do at the prompt.

Press `Enter` alone to execute or step into the current command, or enter one of the
following built-in commands:

* `/help`    Show this help message.
* `/skip`    Skip the current command.
* `/stepout` Execute the rest of the function until it returns; ignores break points.
* `/resume`  Resume the script until the next break point or wherever `tbd.sh` is
             sourced next.

* `/set-break [file_path:]<line_number> [condition]`
  
    Set a break point at a specific `line_number` of a given `file_path`, which
    should be a value from `$BASH_SOURCE` (this is ususally same as `$0`, i.e.,
    the path used to invoke the script, but it might also be the path passed to
    the `source` command). If `file_path` is ommitted, it's assumed to be the file
    of the current line _TBD_ is stepping on.

    A `condition` can be specified as the rest of the line after the line number.
    It's stored as is (no quoting needed; e.g., `/set-break 12 [[ $n == 5 ]]`),
    and `eval`'ed at the break point. The break point will only be activated when
    the `condition` exits with a status of `0`.

* `/list-breaks`  List known break points. The indexes in the first column can be
                  used as arguments to the `/unset-breaks` command.

* `/unset-breaks [index_1 index_2 ...]`
  
    Remove the specified break points given the indexes shown by `/list-breaks`.
    If none is given, all break points will be removed.

Besides the built-in commands listed above, *ANY* shell commands can be run at
the prompt; however, currently, _TBD_ only reads and executes one single line at a time.

Any commands entered will be sent to the corresponding process and evaluated in the
context / scope of the command that the debugger is currently stepping on, but with
output sent to the _TBD_ window.

You can redirect a command's output explicitly to `$TBD_OUT` and/or `$TBD_ERR`, if
you wish to send it to the script's *STDOUT* and/or *STDERR*, respectively. E.g.,

    echo hello >&$TBD_OUT

Finally, whenever a subshell is forked, _TBD_ will switch to a new window in the current
tmux session. Such window will be closed automatically after the subshell terminates.
`Ctrl-C` also terminates the current _TBD_ tmux window or pane.

Tips:
  - To "step over" a function invocation, step into (i.e., `Enter`) the function
    first, then `/stepout`.
  - Run `local -p` inside a function to print its local variables.
  - Run `echo $BASH_COMMAND` to see the current command again.
  - You can set or change any local variables when inside a function.
  - You can `return` from a function, as well as,  `break` or `continue` a loop.
  - You can run a different command and then `/skip` the current command.
  - Use `Ctrl-l` to clear the REPL pane.
EOF
}

declare -A TBD_BREAKS=()    # "file:lineno" -> "condition"

declare -A TBD_SUBSHELL=()  # $BASHPID -> x

tbd-init-window () {
    if [[ ! ${TBD_VIEW_PIPE:-} ]] || [[ $$ != $BASHPID && ! ${TBD_SUBSHELL[$BASHPID]:-} ]]; then
        # NOTE: Not from $RANDOM, which would change the sequence of random
        # numbers the script gets (e.g., if it seeded it).
        TBD_PROMPT_PREFIX=$BASHPID.$(od -An -N8 -tu4 /dev/urandom | tr -d ' \n')
        local output
        if [[ ${TBD_HEADLESS:-} ]]; then
            output=$(tbd-headless "$TBD_PROMPT_PREFIX")
        else
            output=$(tbd-view "$TBD_PROMPT_PREFIX")
        fi
        TBD_SUBSHELL[$BASHPID]=x

        IFS=$'\n' read -d $'\0' -r TBD_{,VIEW_}PIPE TBD_WINDOW_ID <<<"$output"

        if [[ $$ == $BASHPID && ! ${TBD_HEADLESS:-} ]]; then
            tbd-show-help | tbd-cat
        fi
    fi
}

tbd-echo () { echo "$@" > "$TBD_PIPE" && tbd-recv-ack; }
tbd-cat  () { cat > "$TBD_PIPE" && tbd-recv-ack; }

# tbd-read-line <var> <fifo>
#
# Read a line from a FIFO into a variable, waiting for up to 2 seconds for it
# once the FIFO is opened. Returns non-zero on a timeout.
#
# NOTE: The other side opens and closes the FIFO for every message, so when
# we open it right after reading a message from it, the open can succeed
# because the writer of that message hasn't closed it yet; we'd then get an
# EOF without any data. Every line we read ends with a newline, so in that
# case, just open it again.
tbd-read-line () {
    local rc
    while true; do
        IFS= read -t2 -r "$1" < "$2"; rc=$?
        (( rc == 0 )) && return 0
        (( rc > 128 )) && return "$rc"  # timed out
        [[ ! ${!1} ]] || return 0       # a last line without a newline
    done
}

tbd-recv-ack () {
    local fifo=${1:-${TBD_PIPE:?}}
    local reply
    tbd-read-line reply "$fifo" && [[ $reply == ACK ]] || {
        echo "Missing ACK from $fifo" >&2
        return 1
    }
}

tbd-print-current-command () {
    # NOTE: Save it before running any other commands, which could change it.
    local cmd=$BASH_COMMAND

    # Relative source paths are relative to where the script started, not to
    # its current directory (it might have cd'ed) nor to the viewer pane's.
    local src=${BASH_SOURCE[1]}
    while [[ $src == ./* ]]; do src=${src#./}; done
    if [[ $src != /* && -e $TBD_ORIG_PWD/$src ]]; then
        src=$TBD_ORIG_PWD/$src
    elif [[ $src != /* ]]; then
        src=$PWD/$src
    fi
    echo "$src" > "$TBD_VIEW_PIPE" && tbd-recv-ack "$TBD_VIEW_PIPE"
    echo "$TBD_LINENO"       > "$TBD_VIEW_PIPE" && tbd-recv-ack "$TBD_VIEW_PIPE"
    if (( TBD_RC != 0 )); then
        local status=${TBD_LIGHTRED:-}${TBD_RC}${TBD_NC:-}
    else
        local status=${TBD_LIGHTGREEN:-}${TBD_RC}${TBD_NC:-}
    fi
    tbd-echo -e "${TBD_LIGHTBLUE:-}Exit status:${TBD_NC:-} $status"

    # NOTE: Keep compound commands (if, [[ ]], etc.) out of command
    # substitutions in code run from the DEBUG trap; the trap can fire for
    # them in the subshell (with function tracing on), which would recurse.
    local code
    if [[ ${TBD_HEADLESS:-} ]]; then
        code=$(sed 's/^/    /' <<<"$cmd")
    else
        code=$("$TBD_BAT" --decorations never --color "$TBD_BAT_COLOR" -l bash <<<"$cmd" | sed 's/^/    /')
    fi

    tbd-cat <<EOF

At ${BASH_SOURCE[1]}, line $TBD_LINENO:

$code

EOF
}

tbd-print-prompt () {
    local funcnames=$(IFS=\<; echo "${FUNCNAME[*]:1:${#FUNCNAME[*]}-2}")
    [[ $funcnames ]] && funcnames+='()' || funcnames=${0##*/}
    tbd-echo -en "${TBD_PROMPT_PREFIX:?}${TBD_PROMPT_COLOR:-}[$BASHPID] $funcnames:$TBD_LINENO ? ${TBD_NC:-}"
}

# Code to eval when TBD's DEBUG trap is done, to restore what it changed of the
# script's state. NOTE: It's eval'ed, rather than called as a function, as the
# return of a function would fire the script's RETURN trap (functrace is on).
TBD_RESTORE='
    [[ ! $TBD_SET_EU ]] || set "-$TBD_SET_EU"
    if [[ $TBD_TRAPS_SAVED ]]; then
        eval "$TBD_ERR_TRAP"
        [[ $TBD_TRAPS_SAVED == err ]] || eval "$TBD_RET_TRAP"
    fi
'

tbd-set-break () {
    local break=${1:-} cond=${2:-true}
    local lineno=${break##*:} path
    if [[ $break == *:* ]]; then
        path=${break%:*}
    else
        path=${BASH_SOURCE[1]}
    fi

    # NOTE: Not with =~, which would change BASH_REMATCH.
    [[ $lineno && $lineno != *[!0-9]* && $lineno != 0* ]] || {
        echo "Invalid line number: $lineno"
        return
    }
    [[ -e $path ]] || echo "Warning: File not found: $path"
    # NOTE: This is only a warning because if the current working directory might have changed.

    TBD_BREAKS[$path:$lineno]=$cond
}

# Sets the caller's local `breaks` array to the sorted keys of TBD_BREAKS.
tbd-sorted-breaks () {
    breaks=()
    (( ${#TBD_BREAKS[*]} )) || return 0
    mapfile -t breaks < <(printf '%s\n' "${!TBD_BREAKS[@]}" | sort -t: -k1,1 -k2,2n)
}

tbd-unset-breaks () {
    local breaks; tbd-sorted-breaks
    if (( $# )); then
        local i break
        for i in "$@"; do
            break=${breaks[i]}
            [[ $break ]] || continue
            unset "TBD_BREAKS[$break]"
        done
    else
        TBD_BREAKS=()
    fi
}

tbd-list-breaks () (
    local breaks; tbd-sorted-breaks
    local i
    for ((i=0; i < ${#breaks[*]}; i++)); do
        printf "%2d %s\t%s\n" "$i" "${breaks[i]}" "${TBD_BREAKS[${breaks[i]}]}"
    done
)

tbd-debug-trap () {
    # The script might have turned on errexit or nounset after TBD was loaded;
    # turn them off while TBD runs, and restore them when it's done.
    TBD_SET_EU=${-//[^eu]/}; set +eu
    TBD_TRAP_RC=0 TBD_TRAPS_SAVED=

    if [[ ! ${TBD_RESUMING:-} ]] || eval "${TBD_BREAKS[$BASH_SOURCE:$TBD_LINENO]:-false}"; then
        TBD_RESUMING=

        # With extdebug, errtrace and functrace are on, so the script's ERR
        # and RETURN traps would fire for TBD's own failing commands and
        # function returns (and for commands entered at the prompt); set
        # them aside while stopped.
        TBD_ERR_TRAP=$(trap -p ERR) TBD_RET_TRAP=$(trap -p RETURN)
        trap - ERR RETURN
        TBD_TRAPS_SAVED=x

        # Only open a debugger window when we actually stop here, so that
        # subshells running while resuming don't each pop up a window.
        tbd-init-window
        tbd-print-current-command
        [[ ${TBD_HEADLESS:-} ]] || TBD_VIEWING=x

        while true; do
            tbd-print-prompt
            tbd-read-line TBD_CMD "$TBD_PIPE" || TBD_CMD=/resume

            case $TBD_CMD in
                    # Quit the source viewer's pager (once per stop), so that
                    # it's ready to show the next stop.
                    *) [[ ! ${TBD_VIEWING:-} ]] || {
                           tmux send-keys -t ":$TBD_WINDOW_ID.right" q
                           TBD_VIEWING=
                       } ;;&
                    "") TBD_RC=0; break ;;
                /skip) TBD_RC=1; break ;;

                /set-break|/set-break[[:blank:]]*)
                    # Not eval'ed, so that the condition is stored verbatim
                    # and only expanded when the break point is reached.
                    IFS=$' \t\n' read -r TBD_CMD_1 TBD_CMD_2 <<<"${TBD_CMD#/set-break}"
                    tbd-set-break "$TBD_CMD_1" "$TBD_CMD_2" >"$TBD_PIPE" 2>&1
                    tbd-recv-ack "$TBD_PIPE"
                    continue
                    ;;
                /unset-breaks|/unset-breaks\ *) TBD_CMD=tbd-${TBD_CMD#/} ;;
                /list-breaks)     TBD_CMD=tbd-${TBD_CMD#/} ;;

                /stepout)
                    (( ${#FUNCNAME[*]} > 1 )) || {
                        tbd-echo "Error: Not in a function."
                        continue
                    }
                    TBD_DEBUG_TRAP=$(trap -p DEBUG); trap DEBUG; set +T
                    # Once the function returns, restore the script's RETURN
                    # trap, and then the DEBUG trap; last, so that it doesn't
                    # fire for the rest of this RETURN trap.
                    trap '
                        trap - RETURN; eval "$TBD_RET_TRAP"
                        set -T; eval "$TBD_DEBUG_TRAP"
                    ' RETURN
                    TBD_TRAPS_SAVED=err  # the RETURN trap is restored by the above
                    TBD_RC=0; break
                    ;;

                /resume)
                    TBD_RESUMING=x
                    if ! (( ${#TBD_BREAKS[*]} )); then
                        trap DEBUG; shopt -u extdebug; set "-$TBD_ORIG_SET"
                    fi
                    TBD_RC=0; break
                    ;;

                /help) tbd-show-help | tbd-cat; continue ;;
            esac

            IFS=' '$'\t'$'\n' read -r TBD_CMD_1 TBD_CMD_2 <<<"$TBD_CMD"
            case $TBD_CMD_1 in
                break|continue)
                    eval "$TBD_RESTORE"
                    eval "$TBD_CMD_1 $(( ${TBD_CMD_2:-1} + 1 ))"
                    #FIXME: redirect stderr to a file and ship that log to the repl later
                    ;;
                return)
                    (( ${#FUNCNAME[*]} > 1 )) || {
                        tbd-echo "Error: Not in a function."
                        continue
                    }
                    eval "$TBD_RESTORE"
                    eval "$TBD_CMD"
                    #FIXME: redirect stderr to a file and ship that log to the repl later
                    ;;
            esac

            set +T; {TBD_OUT}>&1 {TBD_ERR}>&2 >"$TBD_PIPE" 2>&1 eval "$TBD_CMD"; set -T
            # NOTE: {var} redirections persist beyond the command; close
            # them, so that the script's child processes don't inherit them.
            exec {TBD_OUT}>&- {TBD_ERR}>&-
            tbd-recv-ack "$TBD_PIPE"
        done
        TBD_TRAP_RC=${TBD_RC:-0}
    fi

    eval "$TBD_RESTORE"
    # The trap's status: non-zero makes Bash skip the current command (e.g.,
    # for /skip). Negated with "!", so that errexit, if restored, ignores it.
    # The ":" commands restore $_ (the last argument of the previous command).
    (( TBD_TRAP_RC == 0 )) && : "$TBD_LAST_ARG" || ! : "$TBD_LAST_ARG"
}


TBD_DEBUG_TRAP=$(
    echo 'TBD_RC=$? TBD_LAST_ARG=$_; TBD_LINENO=$LINENO'
    # Enabling extdebug while Bash is still reading its startup files (e.g.,
    # BASH_ENV) makes it try to load the bashdb debugger, and fail. So, in
    # that case, enable it from the DEBUG trap; i.e., once the script starts.
    [[ ! ${TBD_VIA_BASH_ENV:-} ]] || echo 'shopt -s extdebug'
    declare -pf tbd-debug-trap | sed '1,2d;$d'
)


if [[ ${TBD_VIA_BASH_ENV:-} ]]; then
    set -T  # so that the DEBUG trap is inherited until extdebug is enabled
else
    shopt -s extdebug
fi
trap "$TBD_DEBUG_TRAP" DEBUG
