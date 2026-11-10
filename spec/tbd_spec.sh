# shellcheck shell=bash
#
# End-to-end specs for TBD; see spec_helper.sh for the helpers.
#
# NOTE: Fixture line numbers matter; update the specs if you edit fixtures.

Describe 'tbd'
  Describe 'stepping'
    It 'stops at the first command after tbd.sh is sourced'
      scenario() {
        tbd_run "$TBD_FIXTURES/basic.sh"
        tbd_wait_for t:1.0 'basic\.sh:3 \? *$' || return
        tbd_wait_for t:1.1 'echo one' || return  # the source view pane
        tbd_send t:1.0 'echo "cmd=$BASH_COMMAND"' || return
        tbd_last_output t:1.0
        tbd_type t:1.0 /resume
        tbd_wait_done
      }
      When call scenario
      The status should be success
      The output should eq "$(printf '%s\n' 'cmd=echo one' one two three)"
    End

    It 'steps with Enter and skips with /skip'
      scenario() {
        tbd_run "$TBD_FIXTURES/basic.sh"
        tbd_wait_for t:1.0 'basic\.sh:3 \? *$' || return
        tbd_type t:1.0 ''
        tbd_wait_for t:1.0 'basic\.sh:4 \? *$' || return
        tbd_type t:1.0 /skip
        tbd_wait_for t:1.0 'basic\.sh:5 \? *$' || return
        tbd_type t:1.0 ''
        tbd_wait_done
      }
      When call scenario
      The status should be success
      The output should eq "$(printf '%s\n' one three)"
    End

    It 'keeps working after the script changes its working directory'
      scenario() {
        tbd_run "$TBD_FIXTURES/cd.sh"
        tbd_wait_for t:1.0 'cd\.sh:3 \? *$' || return
        tbd_type t:1.0 ''
        tbd_wait_for t:1.0 'cd\.sh:4 \? *$' || return
        tbd_send t:1.0 'echo "PWD=$PWD"' || return
        tbd_last_output t:1.0
        tbd_type t:1.0 /resume
        tbd_wait_done || return
        tbd_wait_cleaned_up || return
        ls -A "$TBD_WORK"  # no stray files left in the original cwd
      }
      When call scenario
      The status should be success
      The output should eq "$(printf '%s\n' 'PWD=/' 'pwd=/' done cd.sh out status)"
    End

    It 'works when the script has changed IFS'
      scenario() {
        tbd_run "$TBD_FIXTURES/ifs.sh"
        tbd_wait_for t:1.0 'ifs\.sh:4 \? *$' || return
        tbd_send t:1.0 'declare -p IFS' || return
        tbd_last_output t:1.0
        tbd_send t:1.0 '/set-break 5' || return
        tbd_type t:1.0 /resume
        tbd_wait_for t:1.0 'ifs\.sh:5 \? *$' || return
        tbd_type t:1.0 /resume
        tbd_wait_done
      }
      When call scenario
      The status should be success
      The output should eq "$(printf '%s\n' 'declare -- IFS=".:0123456789"' a b)"
    End
  End

  Describe 'subshells'
    It 'opens a window for a subshell when stepping into it'
      scenario() {
        tbd_run "$TBD_FIXTURES/subshells.sh"
        tbd_wait_for t:1.0 'subshells\.sh:3 \? *$' || return
        tbd_send t:1.0 '/set-break 5' || return
        tbd_type t:1.0 /resume
        tbd_wait_for t:1.0 'subshells\.sh:5 \? *$' || return
        tbd_type t:1.0 ''
        tbd_wait_for t:2.0 'subshells\.sh:5 \? *$' || return
        tbd_capture t:2.0 | grep -o 'echo inner'
        tbd_type t:2.0 /resume
        tbd_wait_for t:1.0 'subshells\.sh:6 \? *$' || return
        tbd_type t:1.0 /resume
        tbd_wait_done || return
        tbd_wait_cleaned_up || return
        echo "windows=$(tbd_windows_opened)"
      }
      When call scenario
      The status should be success
      The output should eq "$(printf '%s\n' 'echo inner' s3 y=inner windows=2)"
    End

    It 'does not open windows for subshells while resuming'
      scenario() {
        tbd_run "$TBD_FIXTURES/subshells.sh"
        tbd_wait_for t:1.0 'subshells\.sh:3 \? *$' || return
        tbd_send t:1.0 '/set-break 6' || return
        tbd_type t:1.0 /resume
        tbd_wait_for t:1.0 'subshells\.sh:6 \? *$' || return
        echo "windows=$(tbd_windows_opened)"
        tbd_type t:1.0 /resume
        tbd_wait_done || return
        tbd_wait_cleaned_up
      }
      When call scenario
      The status should be success
      The output should eq "$(printf '%s\n' windows=1 s3 y=inner)"
    End

    It 'opens a window only for the subshell hitting a conditional break point'
      scenario() {
        tbd_run "$TBD_FIXTURES/subshells.sh"
        tbd_wait_for t:1.0 'subshells\.sh:3 \? *$' || return
        tbd_send t:1.0 '/set-break 5 [[ $$ != $BASHPID ]]' || return
        tbd_type t:1.0 /resume
        tbd_wait_for t:2.0 'subshells\.sh:5 \? *$' || return
        echo "windows=$(tbd_windows_opened)"
        tbd_type t:2.0 /resume
        tbd_wait_done || return
        tbd_wait_cleaned_up
      }
      When call scenario
      The status should be success
      The output should eq "$(printf '%s\n' windows=2 s3 y=inner)"
    End
  End

  Describe 'break points'
    It 'takes the condition verbatim and evaluates it at the break point'
      scenario() {
        tbd_run "$TBD_ROOT/examples/fizzbuzz"
        tbd_wait_for t:1.0 'fizzbuzz:47 \? *$' || return
        tbd_send t:1.0 '/set-break 13 (( n > 95 ))' || return
        tbd_send t:1.0 '/list-breaks' || return
        tbd_last_output t:1.0
        tbd_type t:1.0 /resume

        # fizzbuzz runs in a subshell (it's in a pipeline).
        tbd_wait_for t:2.0 'fizzbuzz<main\(\):13 \? *$' || return
        tbd_send t:2.0 'echo "n=$n"' || return
        tbd_last_output t:2.0
        tbd_send t:2.0 /resume || return
        tbd_send t:2.0 'echo "n=$n"' || return
        tbd_last_output t:2.0
        tbd_type t:2.0 /resume

        tbd_wait_done | tail -1 || return
        echo "windows=$(tbd_windows_opened)"
      }
      When call scenario
      The status should be success
      The line 1 of output should match pattern ' 0 ./fizzbuzz:13*(( n > 95 ))'
      The line 2 of output should eq 'n=97'
      The line 3 of output should eq 'n=98'
      The line 4 of output should eq '--- The End ---'
      The line 5 of output should eq 'windows=2'
    End

    It 'lists and unsets break points'
      scenario() {
        tbd_run "$TBD_FIXTURES/basic.sh"
        tbd_wait_for t:1.0 'basic\.sh:3 \? *$' || return
        tbd_send t:1.0 '/set-break 5' || return
        tbd_send t:1.0 '/set-break 4' || return
        tbd_send t:1.0 '/list-breaks' || return
        tbd_last_output t:1.0
        echo --
        tbd_send t:1.0 '/unset-breaks 0' || return
        tbd_send t:1.0 '/list-breaks' || return
        tbd_last_output t:1.0
        echo --
        tbd_send t:1.0 '/unset-breaks' || return
        tbd_send t:1.0 '/list-breaks' || return
        tbd_last_output t:1.0
        echo --
        tbd_type t:1.0 /resume
        tbd_wait_done
      }
      When call scenario
      The status should be success
      The line 1 of output should match pattern ' 0 ./basic.sh:4*true'
      The line 2 of output should match pattern ' 1 ./basic.sh:5*true'
      The line 3 of output should eq '--'
      The line 4 of output should match pattern ' 0 ./basic.sh:5*true'
      The line 5 of output should eq '--'
      The line 6 of output should eq ''  # no break points left
      The line 7 of output should eq '--'
      The line 8 of output should eq 'one'
      The lines of output should eq 10
    End

    It 'rejects an invalid line number'
      scenario() {
        tbd_run "$TBD_FIXTURES/basic.sh"
        tbd_wait_for t:1.0 'basic\.sh:3 \? *$' || return
        tbd_send t:1.0 '/set-break' || return
        tbd_last_output t:1.0
        tbd_send t:1.0 '/set-break foo' || return
        tbd_last_output t:1.0
        tbd_send t:1.0 '/list-breaks' || return
        tbd_last_output t:1.0
        tbd_type t:1.0 /resume
        tbd_wait_done >/dev/null
      }
      When call scenario
      The status should be success
      The output should eq "$(printf '%s\n' 'Invalid line number: ' 'Invalid line number: foo')"
    End
  End
End
