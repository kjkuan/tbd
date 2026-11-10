# shellcheck shell=bash
#
# Specs for TBD's headless mode, driven by tbd-ctl; no tmux needed.
#
# NOTE: Fixture line numbers matter; update the specs if you edit fixtures.

Describe 'tbd-ctl'
  # Run tbd-ctl with the session files kept in the example's TMPDIR.
  ctl() { TMPDIR="$TBD_TEST_DIR/tmp" "$TBD_ROOT/tbd-ctl" -t 10 "$@"; }

  stopped_pids() { ctl status | sed -n 's/^\[\([0-9]*\)\] stopped.*/\1/p'; }

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
End
