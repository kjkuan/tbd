#!/usr/bin/env bash

[[ ! "$(trap -p DEBUG)" ]] || return 0

{ { which batcat || which bat; } && which less tmux; } >/dev/null 2>&1 || {
    echo "Please make sure 'bat' / 'batcat', 'less', and 'tmux' are in PATH!"
    exit 1
} >&2

[[ ${TMUX:-} ]] || {
    echo "Please run TBD within a tmux session."
    exit 1
} >&2

TBD_ORIG_SET=${-/i}
set +eu

TBD_HELP=$(cat <<'EOF'
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
Welcome to TBD, the Tiny Bash Debugger!

The '?' is the debugger prompt. '(N)' at the beginning of the prompt is the exit
status of the previous command before entering the DEBUG trap. The line above it
is the current command (not executed yet) the debugger is stepping on. What happens
next depends on what you do at the prompt:

  - Hit 'Enter' alone to execute or step into the current command.
  - 'Ctrl-D' to exit the debugger and resume the script.

Other available debugger commands are:

  /skip     - Skip the current command, resulting in a command status of 1.
  /stepout  - Execute the rest of the function until it returns.
  /help     - Show this help message.
  /resume   - Resume the script until the next break point (i.e., where 'tbd.sh' is
              sourced again)

Besides the built-in commands listed above, *ANY* shell commands can be run at
the prompt; however, currently, TBD only reads and executes one single line at a time.

Any commands entered will be evaluated in the context / scope of the command that the
debugger is currently stepping on, but with output sent to TBD.

You can redirect a command's output explicitly to '$TBD_OUT' and/or '$TBD_ERR', if you wish
to send it to the script's STDOUT and/or STDERR, respectively. E.g.,

    echo hello >&$TBD_OUT

Finally, whenever a subshell is forked, a new tmux window will be created in the current
session. Such window will be closed automatically after the subshell terminates.
'Ctrl-C' also terminates the current TBD tmux window or pane.

Tips:
  - To "step over" a function invocation, step into (i.e., 'Enter') the function
    first, then '/stepout'.
  - Run 'local -p' inside a function to print its local variables.
  - Run 'echo $BASH_COMMAND' to see the current command again.
  - You can set or change any local variables when inside a function.
  - You can 'return' from a function, as well as,  'break' or 'continue' a loop.
  - You can run a different command and then '/skip' the current command.
    This even works in a pipeline so you can change what's being piped through.
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
EOF
)

declare -A TBD_SUBSHELL=()  # $BASHPID -> x

tbd-init-window () {
    if [[ ! ${TBD_VIEW_PIPE:-} ]] || [[ $$ != $BASHPID && ! ${TBD_SUBSHELL[$BASHPID]:-} ]]; then
        TBD_PROMPT_PREFIX=$BASHPID.$RANDOM$RANDOM
        local output; output=$(tbd-view $TBD_PROMPT_PREFIX)
        TBD_SUBSHELL[$BASHPID]=x

        IFS=$'\n' read -d $'\0' -r TBD_{,VIEW_}PIPE TBD_WINDOW_ID <<<"$output"

        if [[ $$ == $BASHPID ]]; then
            tbd-echo "$TBD_HELP"
        fi
    fi
}

tbd-echo () { echo "$@" > "$TBD_PIPE" && tbd-recv-ack; }

tbd-recv-ack () {
    local fifo=${1:-${TBD_PIPE:?}}
    read -t2 -r < "$fifo" && [[ $REPLY == ACK ]] || {
        echo "Missing ACK from $fifo" >&2
        return 1
    }
}

tbd-print-current-command () {
    echo "${BASH_SOURCE[1]}" > "$TBD_VIEW_PIPE" && tbd-recv-ack "$TBD_VIEW_PIPE"
    echo $TBD_LINENO         > "$TBD_VIEW_PIPE" && tbd-recv-ack "$TBD_VIEW_PIPE"
    tbd-echo "${BASH_SOURCE[1]}:$TBD_LINENO: $BASH_COMMAND"
}

tbd-print-prompt () {
    local funcnames=$(IFS=\<; echo "${FUNCNAME[*]:1:${#FUNCNAME[*]}-2}")
    [[ $funcnames ]] && funcnames+='()' || funcnames=${0##*/}
    tbd-echo -n "${TBD_PROMPT_PREFIX:?}($TBD_RC) [$BASHPID] $funcnames:$TBD_LINENO ? "
}

tbd-return () { return $1; }

TBD_DEBUG_TRAP=$(cat <<'EOF'
TBD_RC=$?; TBD_LINENO=$LINENO; tbd-init-window

if [[ ! ${TBD_RETURN_TRAP:-} ]]; then
    tbd-print-current-command

    while true; do
        tbd-print-prompt
        IFS= read -t2 -r TBD_CMD < "$TBD_PIPE"
        if [[ $? != 0 || $TBD_CMD == /resume ]]; then
            trap DEBUG; shopt -u extdebug; set -$TBD_ORIG_SET
            TBD_RC=0; break
        fi

        case $TBD_CMD in
                 *) tmux send-keys -t ":$TBD_WINDOW_ID.right" q ;;&
                "") TBD_RC=0; break ;;
             /skip) TBD_RC=1; break ;;
          /stepout) (( ${#FUNCNAME[*]} > 1 )) || {
                        tbd-echo "Error: Not in a function."
                        continue
                    }
                    set +T; TBD_DEBUG_TRAP=$(trap -p DEBUG); trap DEBUG
                    trap '
                        set -T
                        TBD_RETURN_TRAP=x; trap RETURN
                        eval "$TBD_DEBUG_TRAP"
                    ' RETURN
                    TBD_RC=0; break
                    ;;
            /help) tbd-echo "$TBD_HELP"; continue ;;
        esac

        IFS=' '$'\t'$'\n' read -r TBD_CMD_1 TBD_CMD_2 <<<"$TBD_CMD"
        case $TBD_CMD_1 in
            break|continue)
                eval "$TBD_CMD_1 $(( ${TBD_CMD_2:-1} + 1 ))"
                #FIXME: redirect stderr to a file and ship that log to the repl later
                ;;
            return)
                (( ${#FUNCNAME[*]} > 1 )) || {
                    tbd-echo "Error: Not in a function."
                    continue
                }
                eval "$TBD_CMD"
                #FIXME: redirect stderr to a file and ship that log to the repl later
                ;;
        esac

        [[ ! ${TBD_OUT:-} ]] || eval exec "$TBD_OUT>&-"
        [[ ! ${TBD_ERR:-} ]] || eval exec "$TBD_ERR>&-"

        set +T; {TBD_OUT}>&1 {TBD_ERR}>&2 >"$TBD_PIPE" 2>&1 eval "$TBD_CMD"; set -T
        tbd-recv-ack "$TBD_PIPE"
    done
    tbd-return ${TBD_RC:-0}
else
    TBD_RETURN_TRAP=
fi
EOF
)


shopt -s extdebug
trap "$TBD_DEBUG_TRAP" DEBUG
