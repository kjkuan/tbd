# shellcheck shell=bash
#
# Specs for TBD's headless mode, driven by tbd-ctl; no tmux needed.
#
# NOTE: Fixture line numbers matter; update the specs if you edit fixtures.

Describe 'tbd-ctl'
  # Run tbd-ctl with the session files kept in the example's TMPDIR.
  ctl() { TMPDIR="$TBD_TEST_DIR/tmp" "$TBD_ROOT/tbd-ctl" -t 10 "$@"; }

  stopped_pids() { ctl status | sed -n 's/^\[\([0-9]*\)\] stopped.*/\1/p'; }

  # Print the PID of the stopped process whose next command matches an ERE.
  pid_at() {
    ctl status | awk -v re="$1" '
      /^\[[0-9]+\] stopped/ { pid = substr($1, 2, length($1) - 2); next }
      pid && $0 ~ re { print pid; exit }
    '
  }

  # Wait until at least N processes are stopped.
  wait_stopped() {
    local i
    for (( i=0; i < 100; i++ )); do
      (( $(stopped_pids | wc -l) >= $1 )) && return 0
      sleep 0.1
    done
    return 1
  }

  # Print the PID directories in the current session.
  session_pids() {
    local dir; dir=$(cat "$TBD_TEST_DIR/tmp/tbd-ctl.$(id -u).last")
    ls "$dir" | grep -E '^[0-9]+$'
  }

  # Write a script, from stdin, into the work dir.
  script() { cat > "$TBD_WORK/$1" && chmod +x "$TBD_WORK/$1"; }

  end_session() { ctl end >/dev/null 2>&1 || true; }
  AfterEach 'end_session'

  It 'stops where tbd.sh is sourced, and steps through the script'
    scenario() {
      cp "$TBD_FIXTURES/basic.sh" "$TBD_WORK/"
      cd "$TBD_WORK" || return
      ctl run ./basic.sh | tail -n +4
      local pid; pid=$(stopped_pids)
      ctl step "$pid" | sed "s/$pid/PID/g"
      ctl send "$pid" 'echo "cmd=$BASH_COMMAND"' | sed "s/$pid/PID/g"
      ctl resume "$pid"
      ctl output
    }
    When call scenario
    The status should be success
    The line 1 of output should match pattern '?*? stopped at */basic.sh:3 in basic.sh (last exit status: 0); next command:'
    The line 2 of output should eq '    echo one'
    The line 3 of output should eq '[PID] stopped at '"$TBD_WORK"'/basic.sh:4 in basic.sh (last exit status: 0); next command:'
    The line 4 of output should eq '    echo two'
    The line 5 of output should eq 'cmd=echo two'
    The line 6 of output should eq ''
    The line 7 of output should eq '[PID] stopped at '"$TBD_WORK"'/basic.sh:4 in basic.sh (last exit status: 0); next command:'
    The line 9 of output should match pattern 'The script exited with status 0; *'
    The line 10 of output should eq 'one'
    The line 11 of output should eq 'two'
    The line 12 of output should eq 'three'
  End

  It 'stops at the first command of a script that does not source tbd.sh, with -s'
    scenario() {
      cp "$TBD_FIXTURES/plain.sh" "$TBD_WORK/"
      cd "$TBD_WORK" || return
      ctl run -s ./plain.sh | sed -n 4,5p
    }
    When call scenario
    The status should be success
    The line 1 of output should match pattern '?*? stopped at */plain.sh:2 in plain.sh (last exit status: 0); next command:'
    The line 2 of output should eq '    set -eu'
  End

  It 'keeps the script alive when commands fail under set -eu, and can /skip'
    scenario() {
      cp "$TBD_FIXTURES/plain.sh" "$TBD_WORK/"
      cd "$TBD_WORK" || return
      ctl run -s ./plain.sh >/dev/null
      local pid; pid=$(stopped_pids)
      ctl step "$pid" >/dev/null  # set -eu
      ctl step "$pid" >/dev/null  # x=1
      ctl send "$pid" 'false' | grep -o 'stopped at .*'
      ctl send "$pid" 'echo "${nope}"' | grep -o 'unbound variable\|stopped at .*'
      ctl send "$pid" /skip | grep -o 'stopped at .*'  # skips: echo "x=$x"
      ctl resume "$pid" | grep -o 'exited with status [0-9]*'
      ctl output
    }
    When call scenario
    The status should be success
    The line 1 of output should match pattern 'stopped at */plain.sh:4 in plain.sh (last exit status: 0); next command:'
    The line 2 of output should match pattern 'stopped at */plain.sh:4 in plain.sh (last exit status: 0); next command:'
    The line 3 of output should match pattern 'stopped at */plain.sh:5 in plain.sh (last exit status: 0); next command:'
    The line 4 of output should eq 'exited with status 0'
    The line 5 of output should eq 'done'
    The lines of output should eq 5
  End

  It 'reports subshells that stop at a break point as separate processes'
    scenario() {
      cp "$TBD_FIXTURES/subshells.sh" "$TBD_WORK/"
      cd "$TBD_WORK" || return
      ctl run ./subshells.sh >/dev/null
      local pid; pid=$(stopped_pids)
      ctl send "$pid" '/set-break 5 [[ $$ != $BASHPID ]]' >/dev/null
      ctl resume "$pid" | sed "s/\[$pid\]/[MAIN]/; s/^\[[0-9]*\] stopped/[SUB] stopped/"
      local sub; sub=$(stopped_pids)
      [[ $sub != "$pid" ]] && echo "subshell is a separate process"
      ctl send "$sub" 'echo "$BASHPID"' | head -1 | sed "s/^$sub\$/same pid/"
      ctl resume "$sub" | grep -o 'exited with status [0-9]*'
      ctl output
    }
    When call scenario
    The status should be success
    The line 1 of output should eq '[MAIN] running'
    The line 2 of output should match pattern '?SUB? stopped at */subshells.sh:5 in subshells.sh (last exit status: 0); next command:'
    The line 3 of output should eq '    echo inner'
    The line 4 of output should eq 'subshell is a separate process'
    The line 5 of output should eq 'same pid'
    The line 6 of output should eq 'exited with status 0'
    The line 7 of output should eq 's3'
    The line 8 of output should eq 'y=inner'
  End

  It 'times out, without blocking, when no process stops'
    scenario() {
      printf '%s\n' '#!/usr/bin/env bash' 'source tbd.sh' 'sleep 3' 'echo slept' > "$TBD_WORK/slow.sh"
      chmod +x "$TBD_WORK/slow.sh"
      cd "$TBD_WORK" || return
      ctl run ./slow.sh >/dev/null
      local pid; pid=$(stopped_pids)
      # Step over the sleep, but wait for only 1 second.
      TMPDIR="$TBD_TEST_DIR/tmp" "$TBD_ROOT/tbd-ctl" -t 1 step "$pid" | sed "s/$pid/PID/"
      ctl wait | grep -o 'stopped at .*'
      ctl resume "$pid" | grep -o 'exited with status [0-9]*'
    }
    When call scenario
    The status should be success
    The line 1 of output should eq '(Timed out after 1s waiting for a process to stop.)'
    The line 3 of output should eq '[PID] running'
    The line 4 of output should match pattern 'stopped at */slow.sh:4 in slow.sh (last exit status: 0); next command:'
    The line 5 of output should eq 'exited with status 0'
  End

  It 'kills the script and cleans up with end'
    scenario() {
      cp "$TBD_FIXTURES/basic.sh" "$TBD_WORK/"
      cd "$TBD_WORK" || return
      ctl run ./basic.sh >/dev/null
      local dir; dir=$(cat "$TBD_TEST_DIR/tmp/tbd-ctl.$(id -u).last")
      local pid; pid=$(stopped_pids)
      ctl end
      sleep 0.5
      kill -0 "$pid" 2>/dev/null && echo "still running"
      [[ -e $dir ]] && echo "session dir left"
      ls -A "$TBD_TEST_DIR/tmp"
    }
    When call scenario
    The line 1 of output should match pattern 'Killed the script (pid *).'
    The line 2 of output should eq 'Ended the session.'
    The lines of output should eq 2
  End

  Describe 'safety'
    It 'debugs only the processes of the script, with -s'
      scenario() {
        # 1  #!/usr/bin/env bash
        # 2  x=$(echo sub)
        # 3  bash -c ...
        # 4  echo "x=$x"
        script children.sh <<'EOF'
#!/usr/bin/env bash
x=$(echo sub)
bash -c 'echo "child BASH_ENV=[${BASH_ENV:-}]"'
echo "x=$x"
EOF
        cd "$TBD_WORK" || return
        ctl run -s ./children.sh >/dev/null
        sleep 1  # give a runaway, if any, time to show up
        echo "sessions: $(( $(session_pids | wc -l) ))"
        ctl resume "$(stopped_pids)" | grep -o 'exited with status [0-9]*'
        echo "sessions: $(( $(session_pids | wc -l) ))"
        ctl output
      }
      When call scenario
      The status should be success
      The output should eq "$(printf '%s\n' 'sessions: 1' 'exited with status 0' 'sessions: 1' 'child BASH_ENV=[]' 'x=sub')"
    End

    It 'keeps errexit working after resuming'
      scenario() {
        script errexit.sh <<'EOF'
#!/usr/bin/env bash
set -eu
source tbd.sh
echo before
false
echo unreachable
EOF
        cd "$TBD_WORK" || return
        ctl run ./errexit.sh | grep -o 'errexit.sh:4.*'
        ctl resume "$(stopped_pids)" | grep -o 'exited with status [0-9]*'
        ctl output
      }
      When call scenario
      The status should be success
      The output should eq "$(printf '%s\n' 'errexit.sh:4 in errexit.sh (last exit status: 0); next command:' 'exited with status 1' before)"
    End

    It 'keeps nounset working after resuming'
      scenario() {
        script nounset.sh <<'EOF'
#!/usr/bin/env bash
set -u
source tbd.sh
echo before
echo "$nope"
echo unreachable
EOF
        cd "$TBD_WORK" || return
        ctl run ./nounset.sh >/dev/null
        ctl resume "$(stopped_pids)" | grep -o 'exited with status [0-9]*'
        ctl output
      }
      When call scenario
      The status should be success
      The line 1 of output should eq 'exited with status 1'
      The line 2 of output should eq 'before'
      The line 3 of output should include 'nope: unbound variable'
      The lines of output should eq 3
    End

    It 'keeps errexit set by the script while it was being debugged, with -s'
      scenario() {
        script errexit2.sh <<'EOF'
#!/usr/bin/env bash
set -e
echo before
false
echo unreachable
EOF
        cd "$TBD_WORK" || return
        ctl run -s ./errexit2.sh >/dev/null
        local pid; pid=$(stopped_pids)
        ctl step "$pid" | grep -o 'errexit2.sh:3.*'  # executes: set -e
        ctl resume "$pid" | grep -o 'exited with status [0-9]*'
        ctl output
      }
      When call scenario
      The status should be success
      The output should eq "$(printf '%s\n' 'errexit2.sh:3 in errexit2.sh (last exit status: 0); next command:' 'exited with status 1' before)"
    End
  End

  Describe 'debugger commands'
    It 'runs the rest of a function with /stepout'
      scenario() {
        # 2  f () {      5      echo f3
        # 3      echo f1 6  }
        # 4      echo f2 7  source tbd.sh  8  f  9  echo after
        script stepout.sh <<'EOF'
#!/usr/bin/env bash
f () {
    echo f1
    echo f2
    echo f3
}
source tbd.sh
f
echo after
EOF
        cd "$TBD_WORK" || return
        ctl run ./stepout.sh | grep -o 'stepout.sh:[0-9]* in [^ ]*'
        local pid; pid=$(stopped_pids)
        ctl step "$pid" | grep -o 'stepout.sh:[0-9]* in [^ ]*'  # into f
        ctl step "$pid" | grep -o 'stepout.sh:[0-9]* in [^ ]*'
        ctl send "$pid" /stepout | grep -o 'stepout.sh:[0-9]* in [^ ]*'
        ctl resume "$pid" >/dev/null
        ctl output
      }
      When call scenario
      The status should be success
      The output should eq "$(printf '%s\n' \
        'stepout.sh:8 in stepout.sh' \
        'stepout.sh:2 in f()' \
        'stepout.sh:3 in f()' \
        'stepout.sh:9 in stepout.sh' \
        f1 f2 f3 after)"
    End

    It 'can continue, break, and return at the prompt'
      scenario() {
        #  7  for i in 1 2 3; do    11  g
        #  8      echo "a$i"        12  echo "rc=$?"
        #  9      echo "b$i"
        script control.sh <<'EOF'
#!/usr/bin/env bash
g () {
    echo g1
    echo g2
}
source tbd.sh
for i in 1 2 3; do
    echo "a$i"
    echo "b$i"
done
g
echo "rc=$?"
EOF
        cd "$TBD_WORK" || return
        ctl run ./control.sh >/dev/null
        local pid; pid=$(stopped_pids)
        ctl send "$pid" '/set-break 8' >/dev/null
        ctl resume "$pid" >/dev/null
        ctl send "$pid" 'echo "at i=$i"' | head -1

        # NOTE: The current command still runs before the loop control
        # takes effect; i.e., `echo "a$i"` runs, but `echo "b$i"` doesn't.
        ctl send "$pid" continue >/dev/null
        ctl resume "$pid" >/dev/null
        ctl send "$pid" 'echo "at i=$i"' | head -1
        ctl send "$pid" '/unset-breaks' >/dev/null
        ctl send "$pid" break | grep -o 'control.sh:[0-9]* in [^ ]*'

        ctl step "$pid" >/dev/null  # into g
        ctl send "$pid" 'return 7' | grep -o 'control.sh:[0-9]* in [^ ]*'
        ctl resume "$pid" >/dev/null
        ctl output
      }
      When call scenario
      The status should be success
      The output should eq "$(printf '%s\n' \
        'at i=1' \
        'at i=2' 'control.sh:11 in control.sh' \
        'control.sh:12 in control.sh' \
        a1 a2 'rc=7')"
    End

    It 'changes the state of the script, and writes to its outputs via $TBD_OUT and $TBD_ERR'
      scenario() {
        script state.sh <<'EOF'
#!/usr/bin/env bash
source tbd.sh
name=world
echo "hello $name"
EOF
        cd "$TBD_WORK" || return
        ctl run ./state.sh >/dev/null
        local pid; pid=$(stopped_pids)
        ctl step "$pid" >/dev/null
        ctl send "$pid" 'name=agent' >/dev/null
        ctl send "$pid" 'echo "to stdout" >&$TBD_OUT; echo "to stderr" >&$TBD_ERR' >/dev/null
        ctl resume "$pid" >/dev/null
        ctl output
      }
      When call scenario
      The status should be success
      The output should eq "$(printf '%s\n' 'to stdout' 'to stderr' 'hello agent')"
    End

    It 'stops again where tbd.sh is sourced again, after resuming'
      scenario() {
        script again.sh <<'EOF'
#!/usr/bin/env bash
source tbd.sh
echo one
source tbd.sh
echo two
EOF
        cd "$TBD_WORK" || return
        ctl run ./again.sh | grep -o 'again.sh:[0-9]*'
        local pid; pid=$(stopped_pids)
        ctl resume "$pid" | grep -o 'again.sh:[0-9]*'
        ctl resume "$pid" >/dev/null
        ctl output
      }
      When call scenario
      The status should be success
      The output should eq "$(printf '%s\n' again.sh:3 again.sh:5 one two)"
    End

    It 'sets a break point in a sourced file'
      scenario() {
        script lib.sh <<'EOF'
greet () {
    echo "hi $1"
}
EOF
        script main.sh <<'EOF'
#!/usr/bin/env bash
source tbd.sh
source ./lib.sh
greet a
greet b
EOF
        cd "$TBD_WORK" || return
        ctl run ./main.sh >/dev/null
        local pid; pid=$(stopped_pids)
        ctl send "$pid" '/set-break ./lib.sh:2 [[ $1 == b ]]' >/dev/null
        ctl resume "$pid" | grep -o 'lib.sh:[0-9]* in [^ ]*'
        ctl send "$pid" 'echo "arg=$1"' | head -1
        ctl resume "$pid" >/dev/null
        ctl output
      }
      When call scenario
      The status should be success
      The output should eq "$(printf '%s\n' 'lib.sh:2 in greet()' 'arg=b' 'hi a' 'hi b')"
    End
  End

  Describe 'subshells'
    It 'steps the processes of a pipeline independently'
      scenario() {
        script pipeline.sh <<'EOF'
#!/usr/bin/env bash
source tbd.sh
echo start
{ echo left; } | { read -r x; echo "right got $x"; }
echo end
EOF
        cd "$TBD_WORK" || return
        ctl run ./pipeline.sh >/dev/null
        local main; main=$(stopped_pids)
        # Stepping over `echo start` leads right into the pipeline, whose
        # processes each stop on their own.
        ctl step "$main" >/dev/null
        wait_stopped 2 || { echo "the pipeline didn't stop"; return 1; }
        local left right
        left=$(pid_at '^    echo left$')
        right=$(pid_at '^    read -r x$')
        [[ $left && $right && $left != "$right" ]] && echo "two processes"

        # The right side blocks reading until the left side writes.
        ctl -t 1 step "$right" | grep -o "^\[$right\] running" | sed "s/$right/RIGHT/"
        ctl resume "$left" >/dev/null
        ctl wait | grep -o 'next command:' >/dev/null
        ctl status | grep -A1 "^\[$right\] stopped" | tail -1
        ctl resume "$right" >/dev/null
        ctl wait | grep -o "^\[$main\] stopped" | sed "s/$main/MAIN/"
        ctl resume "$main" >/dev/null
        ctl output
      }
      When call scenario
      The status should be success
      The output should eq "$(printf '%s\n' \
        'two processes' \
        "[RIGHT] running" \
        '    echo "right got $x"' \
        '[MAIN] stopped' \
        start 'right got left' end)"
    End
  End

  Describe 'errors'
    It 'fails clearly without a session'
      When run command env TMPDIR="$TBD_TEST_DIR/tmp" "$TBD_ROOT/tbd-ctl" status
      The status should be failure
      The stderr should eq "tbd-ctl: No debugging session found; start one with: tbd-ctl run <script>"
    End

    It 'rejects bad options and commands'
      scenario() {
        ctl -x status; echo "status=$?"
        ctl frobnicate; echo "status=$?"
        ctl -t abc status; echo "status=$?"
      }
      When call scenario
      The output should eq "$(printf '%s\n' status=1 status=1 status=1)"
      The line 1 of stderr should eq 'tbd-ctl: Unknown option: -x (see: tbd-ctl --help)'
      The line 2 of stderr should eq 'tbd-ctl: Unknown command: frobnicate (see: tbd-ctl --help)'
      The line 3 of stderr should eq 'tbd-ctl: Invalid timeout: abc'
    End

    It 'rejects commands to processes that are not stopped or unknown'
      scenario() {
        printf '%s\n' '#!/usr/bin/env bash' 'source tbd.sh' 'sleep 2' 'echo slept' > "$TBD_WORK/slow.sh"
        chmod +x "$TBD_WORK/slow.sh"
        cd "$TBD_WORK" || return
        ctl run ./slow.sh >/dev/null
        local pid; pid=$(stopped_pids)
        ctl send; echo "status=$?"
        ctl send 1 'echo hi'; echo "status=$?"
        ctl -t 1 step "$pid" >/dev/null
        ctl send "$pid" 'echo hi' 2>&1 | sed "s/$pid/PID/"
        ctl log "$pid" | head -1 | sed "s/$pid/PID/"
        ctl wait >/dev/null; ctl resume "$pid" >/dev/null
        ctl output
      }
      When call scenario
      The output should eq "$(printf '%s\n' \
        status=1 status=1 \
        "tbd-ctl: send: Process PID isn't stopped (it's running)." \
        'Exit status: 0' \
        slept)"
      The line 1 of stderr should eq "tbd-ctl: send: Missing or invalid PID: ''"
      The line 2 of stderr should eq 'tbd-ctl: send: No debugged process 1 in this session.'
    End
  End
End
