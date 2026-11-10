#!/usr/bin/env bash

[[ ! "$(trap -p DEBUG)" ]] || return 0

{ { which batcat || which bat; } && which less tmux; } >/dev/null 2>&1 || {
    echo "Please make sure 'bat' / 'batcat', 'less', and 'tmux' are in PATH!"
    exit 1
} >&2

if which batcat >/dev/null 2>&1; then bat () { batcat "$@"; }; fi

[[ ${TMUX:-} ]] || {
    echo "Please run TBD within a tmux session."
    exit 1
} >&2

TBD_ORIG_SET=${-/i}
TBD_ORIG_PWD=${TBD_ORIG_PWD:-$PWD}
set +eu

# NOTE: The script being debugged might have changed IFS, so avoid relying
# on word splitting in any code that runs in the script's context.

if [[ ${NO_COLOR:-} ]]; then TBD_BAT_COLOR=never; else TBD_BAT_COLOR=always; fi

if [[ ! ${NO_COLOR:-} ]]; then
    TBD_NC='\e[0m'
    TBD_LIGHTRED='\e[1;31m'
    TBD_LIGHTGREEN='\e[1;32m'
    TBD_LIGHTBLUE='\e[1;34m'
    TBD_PROMPT_COLOR=${TBD_PROMPT_COLOR:-${TBD_LIGHTBLUE:-}}
fi


tbd-show-help () {
    bat --decorations never  \
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
        TBD_PROMPT_PREFIX=$BASHPID.$RANDOM$RANDOM
        local output; output=$(tbd-view "$TBD_PROMPT_PREFIX")
        TBD_SUBSHELL[$BASHPID]=x

        IFS=$'\n' read -d $'\0' -r TBD_{,VIEW_}PIPE TBD_WINDOW_ID <<<"$output"

        if [[ $$ == $BASHPID ]]; then
            tbd-show-help | tbd-cat
        fi
    fi
}

tbd-echo () { echo "$@" > "$TBD_PIPE" && tbd-recv-ack; }
tbd-cat  () { cat > "$TBD_PIPE" && tbd-recv-ack; }

tbd-recv-ack () {
    local fifo=${1:-${TBD_PIPE:?}}
    local reply
    IFS= read -t2 -r reply < "$fifo" && [[ $reply == ACK ]] || {
        echo "Missing ACK from $fifo" >&2
        return 1
    }
}

tbd-print-current-command () {
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

    tbd-cat <<EOF

At ${BASH_SOURCE[1]}, line $TBD_LINENO:

$(bat --decorations never  \
      --color "$TBD_BAT_COLOR" \
      -l bash <<<"$BASH_COMMAND" \
   | sed 's/^/    /'
)

EOF
}

tbd-print-prompt () {
    local funcnames=$(IFS=\<; echo "${FUNCNAME[*]:1:${#FUNCNAME[*]}-2}")
    [[ $funcnames ]] && funcnames+='()' || funcnames=${0##*/}
    tbd-echo -en "${TBD_PROMPT_PREFIX:?}${TBD_PROMPT_COLOR:-}[$BASHPID] $funcnames:$TBD_LINENO ? ${TBD_NC:-}"
}

tbd-restore-eu () { [[ ! $TBD_SET_EU ]] || set "-$TBD_SET_EU"; }

tbd-set-break () {
    local break=${1:-} cond=${2:-true}
    local lineno=${break##*:} path
    if [[ $break == *:* ]]; then
        path=${break%:*}
    else
        path=${BASH_SOURCE[1]}
    fi

    [[ $lineno =~ ^[1-9][0-9]*$ ]] || {
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
    TBD_TRAP_RC=0

    if [[ ! ${TBD_RESUMING:-} ]] || eval "${TBD_BREAKS[$BASH_SOURCE:$TBD_LINENO]:-false}"; then
        TBD_RESUMING=

        if [[ ! ${TBD_RETURN_TRAP:-} ]]; then

            # Only open a debugger window when we actually stop here, so that
            # subshells running while resuming don't each pop up a window.
            tbd-init-window
            tbd-print-current-command
            TBD_VIEWING=x

            while true; do
                tbd-print-prompt
                IFS= read -t2 -r TBD_CMD < "$TBD_PIPE"
                if [[ $? != 0 ]]; then TBD_CMD=/resume; fi

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
                        trap '
                            TBD_RETURN_TRAP=$FUNCNAME
                            set -T; eval "$TBD_DEBUG_TRAP"; trap RETURN
                        ' RETURN
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
                        tbd-restore-eu
                        eval "$TBD_CMD_1 $(( ${TBD_CMD_2:-1} + 1 ))"
                        #FIXME: redirect stderr to a file and ship that log to the repl later
                        ;;
                    return)
                        (( ${#FUNCNAME[*]} > 1 )) || {
                            tbd-echo "Error: Not in a function."
                            continue
                        }
                        tbd-restore-eu
                        eval "$TBD_CMD"
                        #FIXME: redirect stderr to a file and ship that log to the repl later
                        ;;
                esac

                [[ ! ${TBD_OUT:-} ]] || eval exec "$TBD_OUT>&-"
                [[ ! ${TBD_ERR:-} ]] || eval exec "$TBD_ERR>&-"

                set +T; {TBD_OUT}>&1 {TBD_ERR}>&2 >"$TBD_PIPE" 2>&1 eval "$TBD_CMD"; set -T
                tbd-recv-ack "$TBD_PIPE"
            done
            TBD_TRAP_RC=${TBD_RC:-0}
        else
            TBD_RETURN_TRAP=
        fi
    fi

    tbd-restore-eu
    # The trap's status: non-zero makes Bash skip the current command (e.g.,
    # for /skip). Negated with "!", so that errexit, if restored, ignores it.
    (( TBD_TRAP_RC == 0 )) || ! :
}


TBD_DEBUG_TRAP=$(
    echo 'TBD_RC=$?; TBD_LINENO=$LINENO'
    declare -pf tbd-debug-trap | sed '1,2d;$d'
)


shopt -s extdebug
trap "$TBD_DEBUG_TRAP" DEBUG
