# shellcheck shell=bash
#
# Helpers for driving TBD end-to-end inside an isolated tmux server.
#
# Each example gets its own tmux server (-L socket), HOME, and TMPDIR, so it
# doesn't touch the user's tmux session, ~/.tbd_history, or /tmp. Window 0
# runs the script being debugged (stdout/stderr -> $TBD_WORK/out); window 1
# is the main process's debugger REPL (pane 0) and source view (pane 1), and
# windows 2+ are subshells' debugger windows.

TBD_ROOT=$SHELLSPEC_PROJECT_ROOT
TBD_FIXTURES=$TBD_ROOT/spec/fixtures
TBD_TIMEOUT=${TBD_TIMEOUT:-15}  # seconds

spec_helper_precheck() {
    minimum_version "0.28.1"
}

spec_helper_configure() {
    before_each 'tbd_setup'
    after_each 'tbd_teardown'
}

tbd_setup() {
    # NOTE: Strip the trailing slash TMPDIR has on macOS, as paths in TBD's
    # output won't have the "//" it'd cause.
    local tmp=${TMPDIR:-/tmp}
    TBD_TEST_DIR=$(mktemp -d "${tmp%/}/tbd-spec.XXXXXXXX")
    TBD_WORK=$TBD_TEST_DIR/work
    TBD_SOCKET=tbd-spec-$$-$RANDOM
    mkdir "$TBD_TEST_DIR"/{home,tmp,bin,work}

    # Wrapper that records every debugger window TBD opens.
    cat > "$TBD_TEST_DIR/bin/tbd-view" <<EOF
#!/usr/bin/env bash
echo "\$1" >> "$TBD_TEST_DIR/views.log"
exec "$TBD_ROOT/tbd-view" "\$@"
EOF
    chmod +x "$TBD_TEST_DIR/bin/tbd-view"
    : > "$TBD_TEST_DIR/views.log"
}

tbd_teardown() {
    tmux -L "$TBD_SOCKET" kill-server >/dev/null 2>&1 || true
    rm -rf "${TBD_TEST_DIR:?}"
}

T() { tmux -L "$TBD_SOCKET" "$@"; }

# tbd_run <script> [cmd-prefix]
#
# Copy a fixture (or any script) into the work dir and run it from there, in
# window 0 of a new tmux server.
tbd_run() {
    local src=$1 name=${1##*/}
    cp "$src" "$TBD_WORK/$name"
    local cmd="cd $(printf %q "$TBD_WORK") && ${2:-} ./$(printf %q "$name") >out 2>&1; echo \$? >status"

    env HOME="$TBD_TEST_DIR/home" \
        TMPDIR="$TBD_TEST_DIR/tmp" \
        PATH="$TBD_TEST_DIR/bin:$TBD_ROOT:$PATH" \
        SHELL=/bin/bash \
        tmux -L "$TBD_SOCKET" -f /dev/null \
            new-session -d -s t -x 250 -y 50 "bash -c $(printf %q "$cmd")"
}

tbd_capture() { T capture-pane -p -J -S - -t "$1" 2>/dev/null; }

# tbd_wait_for <target> <ERE> [timeout]
tbd_wait_for() {
    local i n=$(( ${3:-$TBD_TIMEOUT} * 10 ))
    for (( i=0; i < n; i++ )); do
        tbd_capture "$1" | grep -Eq -- "$2" && return 0
        sleep 0.1
    done
    echo "Timed out waiting for /$2/ in pane $1; it has:" >&2
    tbd_capture "$1" >&2
    return 1
}

tbd_prompt_count() {
    tbd_capture "$1" | grep -Ec '^\[[0-9]+\] [^ ]*:[0-9]+ \? '
}

# tbd_type <target> <line>
#
# Type a line at a REPL without waiting for anything.
tbd_type() {
    [[ ! $2 ]] || T send-keys -t "$1" -l -- "$2"
    T send-keys -t "$1" Enter
}

# tbd_send <target> <line>
#
# Type a line at a REPL and wait for the next prompt in the same pane.
tbd_send() {
    local before; before=$(tbd_prompt_count "$1")
    tbd_type "$1" "$2"
    local i n=$(( TBD_TIMEOUT * 10 ))
    for (( i=0; i < n; i++ )); do
        (( $(tbd_prompt_count "$1") > before )) && return 0
        sleep 0.1
    done
    echo "Timed out waiting for a prompt after '$2' in pane $1; it has:" >&2
    tbd_capture "$1" >&2
    return 1
}

# Output of the most recent command typed at a REPL pane, i.e., the lines
# between the last two prompts.
tbd_last_output() {
    tbd_capture "$1" | awk '
        /^\[[0-9]+\] [^ ]*:[0-9]+ \? / { prev = out; out = ""; next }
        { out = out $0 "\n" }
        END { printf "%s", prev }
    '
}

# Wait for the debugged script to exit; print its output.
tbd_wait_done() {
    local i n=$(( TBD_TIMEOUT * 10 ))
    for (( i=0; i < n; i++ )); do
        if [[ -s $TBD_WORK/status ]]; then
            cat "$TBD_WORK/out"
            return "$(cat "$TBD_WORK/status")"
        fi
        sleep 0.1
    done
    echo "Timed out waiting for the script to exit" >&2
    return 1
}

# Wait until all debugger windows have closed; fail if they left files behind.
tbd_wait_cleaned_up() {
    local i n=$(( TBD_TIMEOUT * 10 ))
    for (( i=0; i < n; i++ )); do
        T has-session -t t >/dev/null 2>&1 || break
        sleep 0.1
    done
    # The debugger's processes clean up as they exit; give them a moment.
    local leftovers
    for (( i=0; i < 20; i++ )); do
        leftovers=$(ls -A "$TBD_TEST_DIR/tmp")
        [[ $leftovers ]] || break
        sleep 0.1
    done
    [[ ! $leftovers ]] || {
        echo "Leftover files in TMPDIR: $leftovers" >&2
        return 1
    }
}

tbd_windows_opened() { echo $(( $(wc -l < "$TBD_TEST_DIR/views.log") )); }
