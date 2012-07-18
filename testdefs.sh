# Common definitions for all test suites.
# Copyright 2012 The Serval Project, Inc.
#
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License
# as published by the Free Software Foundation; either version 2
# of the License, or (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301, USA.

shopt -s extglob

testdefs_sh=$(abspath "${BASH_SOURCE[0]}")
servald_source_root="${testdefs_sh%/*}"
servald_build_root="$servald_source_root"
servald_build_executable="$servald_build_root/dna"
export TFW_LOGDIR="${TFW_LOGDIR:-$servald_build_root/testlog}"

declare -a instance_stack=()

# Some useful regular expressions.  These must work in grep(1) as basic
# expressions, and also in sed(1).
rexp_sid='[0-9a-fA-F]\{64\}'
rexp_did='[0-9+#]\{5,\}'

# Utility function for extracting information from the output of servald
# commands that return "key:value\n" pairs.
extract_stdout_keyvalue_optional() {
   local _var="$1"
   local _label="$2"
   local _rexp="$3"
   local _line=$(replayStdout | grep "^$_label:")
   local _value=
   local _return=1
   if [ -n "$_line" ]; then
      _value="${_line#*:}"
      _return=0
   fi
   [ -n "$_var" ] && eval $_var="$_value"
   return $_return
}

# Utility function for extracting information from the output of servald
# commands that return "key:value\n" pairs.
extract_stdout_keyvalue() {
   local _label="$2"
   assert --message="stdout of ($executed) contains valid '$_label:' line" --stdout extract_stdout_keyvalue_optional "$@"
}

# Utility function for creating servald fixtures:
#  - set $servald variable (executable under test)
#  - set the current instance to be "Z"
setup_servald() {
   export SERVALD_VAR=$TFWVAR/servald
   mkdir $SERVALD_VAR
   servald_basename=servald
   servald=$SERVALD_VAR/$servald_basename # The servald executable under test
   if ! [ -x "$servald_build_executable" ]; then
      error "servald executable not present: $servald"
      return 1
   fi
   ln -f -s "$servald_build_executable" $servald
   unset SERVALD_OUTPUT_DELIMITER
   unset SERVALD_SERVER_START_DELAY
   unset SERVALD_LOG_FILE
   servald_instances_dir="$SERVALD_VAR/instance"
   set_instance +Z
}

# Utility function for running servald and asserting no errors:
#  - executes $servald with the given arguments
#  - asserts that standard error contains no error messages
executeOk_servald() {
   executeOk --executable=$servald "$@"
   assertStderrGrep --matches=0 --message="stderr of ($executed) contains no error messages" '^ERROR:'
}

# Utility function:
#  - if the argument is a prefixed instance name "+X", then call set_instance
#    "X" and return 0, otherwise leave the current instance unchanged and return 1
# Designed for use in functions that take an optional instance name as their
# first argument:
#     func() {
#        push_instance
#        set_instance_fromarg "$1" && shift
#        ...
#        pop_instance
#     }
# would be invoked as:
#     func +A blah blah
#     func +B wow wow
#     func foo bar
set_instance_fromarg() {
   case "$1" in
   +[A-Z]) set_instance "$1"; return 0;;
   esac
   return 1
}

# Utility function:
#  - push the current instance on the instance stack
push_instance() {
   instance_stack+=("$instance_name")
}

# Utility function:
#  - pop an instance off the instance stack
pop_instance() {
   local n=${#instance_stack[*]}
   [ $n -eq 0 ] && error "instance stack underflow"
   let --n
   unset instance_stack[$n]
}

# Utility function:
#  - create a temporary directory to contain all per-instance test files
#  - set SERVALINSTANCE_PATH environment variable to name a directory within
#    the per-instance test directory (but do not create it)
#  - set other environment variables to support other functions defined in this
#    script
set_instance() {
   case "$1" in
   '')
      error "missing instance name argument"
      ;;
   +[A-Z])
      instance_name="${1#+}"
      instance_number=$((36#$instance_name - 9))
      tfw_log "# set instance = $instance_name, number = $instance_number"
      export instance_dir="${servald_instances_dir?:}/$instance_name"
      mkdir -p "$instance_dir"
      export SERVALINSTANCE_PATH="$instance_dir/servald"
      instance_servald_log="$instance_dir/servald.log"
      instance_servald_pidfile="$SERVALINSTANCE_PATH/servald.pid"
      ;;
   *)
      error "malformed instance name argument, must be in form +[A-Z]"
      ;;
   esac
}

# Utility function for setting up servald JNI fixtures:
#  - check that libservald.so is present
#  - set LD_LIBRARY_PATH so that libservald.so can be found
setup_servald_so() {
   assert [ -r "$servald_build_root/libservald.so" ]
   export LD_LIBRARY_PATH="$servald_build_root"
}

# Utility function for setting up a fixture with a servald server process:
#  - start a servald server process
#  - assert that the pidfile is created and correct
#  - set $servald_pid to the PID of the started server process
#  - assert that the reported PID is actually a running servald process
start_servald_server() {
   push_instance
   set_instance_fromarg "$1" && shift
   # Start servald server
   local -a before_pids
   local -a after_pids
   get_servald_pids before_pids
   tfw_log "# before_pids=$before_pids"
   SERVALD_LOG_FILE="$instance_servald_log" executeOk $servald start "$@"
   extract_stdout_keyvalue start_instance_path instancepath '.*'
   extract_stdout_keyvalue start_pid pid '[0-9]\+'
   assert [ "$start_instance_path" = "$SERVALINSTANCE_PATH" ]
   get_servald_pids after_pids
   tfw_log "# after_pids=$after_pids"
   assert_servald_server_pidfile servald_pid
   # Assert that the servald pid file is present.
   assert --message="servald pidfile was created" [ -s "$instance_servald_pidfile" ]
   assert --message="servald pidfile contains a valid pid" --dump-on-fail="$instance_servald_log" kill -0 "$servald_pid"
   assert --message="servald start command returned correct pid" [ "$start_pid" -eq "$servald_pid" ]
   # Assert that there is at least one new servald process running.
   local apid bpid
   local new_pids=
   local pidfile_running=false
   for apid in ${after_pids[*]}; do
      local isnew=true
      for bpid in ${before_pids[*]}; do
         if [ "$apid" -eq "$bpid" ]; then
            isnew=false
            break
         fi
      done
      if [ "$apid" -eq "$servald_pid" ]; then
         tfw_log "# started servald process: pid=$servald_pid"
         new_pids="$new_pids $apid"
         pidfile_running=true
      elif $isnew; then
         tfw_log "# unknown new servald process: pid=$apid"
         new_pids="$new_pids $apid"
      fi
   done
   assert --message="a new servald process is running" --dump-on-fail="$instance_servald_log" [ -n "$new_pids" ]
   assert --message="servald pidfile process is running" --dump-on-fail="$instance_servald_log" $pidfile_running
   assert --message="servald log file $instance_servald_log is present" [ -r "$instance_servald_log" ]
   tfw_log "# Started servald server process $instance_name, pid=$servald_pid"
   pop_instance
}

# Utility function:
#  - stop a servald server process instance in an orderly fashion
#  - cat its log file into the test log
stop_servald_server() {
   push_instance
   set_instance_fromarg "$1" && shift
   # Stop servald server
   get_servald_server_pidfile servald_pid
   local -a before_pids
   local -a after_pids
   get_servald_pids before_pids
   tfw_log "# before_pids=$before_pids"
   execute $servald stop "$@"
   extract_stdout_keyvalue stop_instance_path instancepath '.*'
   assert [ "$stop_instance_path" = "$SERVALINSTANCE_PATH" ]
   if [ -n "$servald_pid" ]; then
      extract_stdout_keyvalue stop_pid pid '[0-9]\+'
      assert [ "$stop_pid" = "$servald_pid" ]
   fi
   tfw_log "# Stopped servald server process $instance_name, pid=${servald_pid:-unknown}"
   get_servald_pids after_pids
   tfw_log "# after_pids=$after_pids"
   # Assert that the servald pid file is gone.
   assert --message="servald pidfile was removed" [ ! -e "$instance_servald_pidfile" ]
   # Assert that the servald process identified by the pidfile is no longer running.
   local apid bpid
   if [ -n "$servald_pid" ]; then
      for apid in ${after_pids[*]}; do
         assert --message="servald process still running" [ "$apid" -ne "$servald_pid" ]
      done
   fi
   # Append the server log file to the test log.
   [ -s "$instance_servald_log" ] && tfw_cat "$instance_servald_log"
   # Check there is at least one fewer servald processes running.
   for bpid in ${before_pids[*]}; do
      local isgone=true
      for apid in ${after_pids[*]}; do
         if [ "$apid" -eq "$bpid" ]; then
            isgone=false
            break
         fi
      done
      if $isgone; then
         tfw_log "# ended servald process: pid=$bpid"
      fi
   done
   pop_instance
}

# Utility function:
#  - test whether the pidfile for a given server instance exists and is valid
#  - if it exists and is valid, set named variable to PID (and second named
#    variable to path of pidfile) and return 0
#  - otherwise return 1
get_servald_server_pidfile() {
   local _pidvar="$1"
   local _pidfilevar="$2"
   push_instance
   set_instance_fromarg "$1" && shift
   local _pidfile="$instance_servald_pidfile"
   pop_instance
   [ -n "$_pidfilevar" ] && eval $_pidfilevar="$_pidfile"
   local _pid=$(cat "$_pidfile" 2>/dev/null)
   case "$_pid" in
   +([0-9]))
      [ -n "$_pidvar" ] && eval $_pidvar="$_pid"
      return 0
      ;;
   '')
      if [ -e "$_pidfile" ]; then
         tfw_log "# empty pidfile $_pidfile"
      else
         tfw_log "# missing pidfile $_pidfile"
      fi
      ;;
   *)
      tfw_log "# invalid pidfile $_pidfile"
      tfw_cat "$_pidfile"
      ;;
   esac
   return 1
}

# Assertion function:
#  - asserts that the servald server pidfile exists and contains a valid PID
#  - does NOT check whether a process with that PID exists or whether that
#    process is a servald process
assert_servald_server_pidfile() {
   assert get_servald_server_pidfile "$@"
}

# Utility function for tearing down servald fixtures:
#  - stop all servald server process instances in an orderly fashion
stop_all_servald_servers() {
   push_instance
   if pushd "${servald_instances_dir?:}" >/dev/null; then
      for name in *; do
         set_instance "+$name"
         get_servald_server_pidfile && stop_servald_server
      done
      popd >/dev/null
   fi
   pop_instance
}

# Utility function for tearing down servald fixtures:
#  - send a given signal to all running servald processes, identified by name
#  - return 1 if no processes were present, 0 if any signal was sent
signal_all_servald_processes() {
   local sig="$1"
   local servald_pids
   get_servald_pids servald_pids
   local pid
   local ret=1
   for pid in $servald_pids; do
      if kill -$sig "$pid"; then
         tfw_log "# Sent SIG$sig to servald process pid=$pid"
         ret=0
      else
         tfw_log "# servald process pid=$pid not running -- SIG$sig not sent"
      fi
   done
   return $ret
}

# Utility function for tearing down servald fixtures:
#  - wait while any servald processes remain
#  - return 0 if no processes are present
#  - 1 if the timeout elapses first
wait_all_servald_processes() {
   local timeout="${1:-1000000}"
   sleep $timeout &
   sleep_pid=$!
   while get_servald_pids; do
      kill -0 $sleep_pid 2>/dev/null || return 1
      sleep 0.1
   done
   kill -TERM $sleep_pid 2>/dev/null
   return 0
}

# Utility function for tearing down servald fixtures:
#  - terminate all running servald processes, identified by name, by sending
#    two SIGHUPs 100ms apart, then another SIGHUP after 2 seconds, finally
#    SIGKILL after 2 seconds
#  - return 0 if no more processes are running, nonzero otherwise
kill_all_servald_processes() {
   for delay in 0.1 2 2; do
      signal_all_servald_processes HUP || return 0
      wait_all_servald_processes $delay && return 0
   done
   signal_all_servald_processes KILL || return 0
   return 1
}

# Utility function:
#  - return the PIDs of all servald processes the current test is running, by
#    assigning to the named array variable if given
#  - return 0 if there are any servald processes running, 1 if not
get_servald_pids() {
   local var="$1"
   if [ -z "$servald" ]; then
      error "\$servald is not set"
      return 1
   fi
   local mypid=$$
   # XXX The following line will not find any PIDs if there are spaces in "$servald".
   local pids=$(ps -u$UID -o pid,args | awk -v mypid="$mypid" -v servald="$servald" '$1 != mypid && $2 == servald {print $1}')
   [ -n "$var" ] && eval "$var=($pids)"
   [ -n "$pids" ]
}

# Assertion function:
#  - assert there are no existing servald server processes
assert_no_servald_processes() {
   local pids
   get_servald_pids pids
   assert --message="$servald_basename process(es) running: $pids" [ -z "$pids" ]
   return 0
}

# Assertion function:
#  - assert the given instance's servald server log contains no errors
assert_servald_server_no_errors() {
   push_instance
   set_instance_fromarg "$1" && shift
   assertGrep --matches=0 --message="stderr of $servald_basename $instance_name contains no error messages" "$instance_servald_log" '^ERROR:'
   pop_instance
}

# Assertion function:
#  - assert that all instances of servald server logs contain no errors
assert_all_servald_servers_no_errors() {
   push_instance
   if pushd "${servald_instances_dir?:}" >/dev/null; then
      for name in *; do
         set_instance "+$name"
         assertGrep --matches=0 --message="stderr of $servald_basename $instance_name contains no error messages" "$instance_servald_log" '^ERROR:'
      done
      popd >/dev/null
   fi
   pop_instance
}

# Utility function
#  - create an identity
#  - assign a phone number (DID) and name to the new identity, use defaults
#    if not specified by arg1 and arg2
#  - set the SID variable to the SID of the new identity
#  - set the NUMBER variable to the phone number of the new identity
#  - set the NAME variable to the name of the new identity
create_identity() {
   executeOk_servald keyring add
   assert [ -e "$SERVALINSTANCE_PATH/serval.keyring" ]
   executeOk_servald keyring list
   SID=$(replayStdout | sed -ne "1s/^\($rexp_sid\):.*\$/\1/p")
   assert --message='main identity known' [ -n "$SID" ]
   NUMBER="${1-$((5550000 + $instance_number))}"
   NAME="${2-Agent $instance_name Smith}"
   executeOk_servald set did $SID "$NUMBER" "$NAME"
   tfw_log "Identity $instance_name: $SID $NUMBER $NAME"
}

# Utility function, to be overridden as needed:
#  - set up the configuration immediately prior to starting a servald server
#    process
#  - called by start_servald_instances
configure_servald_server() {
   :
}

# Utility function:
#  - start a set of servald server processes running on a shared dummy interface
#    and with its own private monitor and MDP abstract socket names
#  - set variable DUMMYNET to the full path name of shared dummy interface
#  - set variables SIDx to the SID of instance x: SIDA, SIDB, etc.
#  - set variables LOGx to the full path of server log file for instance x: LOGA,
#    LOGB, etc,
#  - wait for all instances to detect each other
#  - assert that all instances are in each others' peer lists
start_servald_instances() {
   push_instance
   tfw_log "# start servald instances $*"
   DUMMYNET=$SERVALD_VAR/dummy
   >$DUMMYNET
   local I J
   for I; do
      set_instance $I
      create_identity
      executeOk_servald config set interfaces "+>$DUMMYNET"
      executeOk_servald config set monitor.socket "org.servalproject.servald.monitor.socket.$TFWUNIQUE.$instance_name"
      executeOk_servald config set mdp.socket "org.servalproject.servald.mdp.socket.$TFWUNIQUE.$instance_name"
      configure_servald_server
      start_servald_server
      eval SID${I#+}="$SID"
      eval LOG${I#+}="$instance_servald_log"
   done
   # Now wait until they see each other.
   wait_until --sleep=0.25 instances_see_each_other "$@"
   tfw_log "# dummynet file:" $(ls -l $DUMMYNET)
   # Assert that all instances report complete all-peer lists.
   for I; do
      set_instance $I
      executeOk_servald id allpeers
      assertStdoutLineCount '==' $(($# - 1))
      for J; do
         [ $I = $J ] && continue
         local sidvar=SID${J#+}
         assertStdoutGrep "${!sidvar}"
      done
   done
   pop_instance
}

instances_see_each_other() {
   local I J
   for I; do
      for J; do
         [ $I = $J ] && continue
         local logvar=LOG${I#+}
         local sidvar=SID${J#+}
         if ! grep "ADD OVERLAY NODE sid=${!sidvar}" "${!logvar}"; then
            return 1
         fi
      done
   done
   return 0
}
