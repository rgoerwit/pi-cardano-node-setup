#!/bin/bash
#
#############################################################################
#
#  Source this file to get locking and concurrency control
#
#############################################################################

# This is all the locking and signal-trapping crap we need in order to 
# ensure we don't have two copies of this script running at once.  Look
# for the string --- REAL CODE --- below (after all the locking stuff)
#
# Set up a few basic variables:  PROGNAME, TMPFILE, LOGFILE
#
if declare -F err_exit 1> /dev/null; then
	: do nothing
else
err_exit() {
	  EXITCODE="$1"; shift
	  (printf "$*" && echo -e "") 1>&2; 
	  # pushd -0 >/dev/null && dirs -c
	  exit $EXITCODE 
	}
fi

PROGNAME=$(basename $0)
TMPFILE=`mktemp ${TMPDIR:-/tmp}/$PROGNAME.XXXXXXXXXX`
([ "$?" -ne '0' ] || [ -z "$TMPFILE" ]) && err_exit 2 "$0: Can't create temporary file, $TMPFILE; aborting"
LOGFILE=`mktemp ${TMPDIR:-/tmp}/$PROGNAME-log.XXXXXXXXXX`
([ "$?" -ne '0' ] || [ ".$LOGFILE" = '.' ]) && err_exit 2 "$0: Can't create log file, $LOGFILE; aborting"

# Now start creating lockfiles and trapping interrupts
#
TEMPDIR="${TEMP:-/tmp}"

TEMPLOCKFILE=`mktemp $TEMPDIR/${PROGNAME}.XXXXXX 2> /dev/null`
[ -z "$TEMPLOCKFILE" ] && exit 15 "$0: Can't create $TEMPLOCKFILE; do you have sufficient permissions?"
echo -n "$$" >> "$TEMPLOCKFILE"
chmod a+r "$TEMPLOCKFILE"
chmod g+w "$TEMPLOCKFILE"
# echo "Created $TEMPLOCKFILE"

nixtempfile () {
  [ -f "$TEMPLOCKFILE" ] && rm -f "$TEMPLOCKFILE" 2> /dev/null
  [ -z "$1" ] && err_exit 17 "$0: Interrupted; removed tempfile, $TEMPLOCKFILE" 
}

# If script gets killed or hung up on, remove lockfile
if [ -f "$TEMPLOCKFILE" ]; then
  trap nixtempfile 1 2 3 15
else
  err_exit 19 "$0: Temporary file, $TEMPLOCKFILE, is missing; aborting"
fi

nixlockfile () {
  nixtempfile 1
  [ -f "$LOCKFILE" ] && rm -f "$LOCKFILE" 2> /dev/null
  err_exit 21 "$0: Interrupted; removed lockfile, $LOCKFILE"
}

LOCKFILE="$TEMPDIR/.${PROGNAME}.lock"

if test -e "$LOCKFILE"; then
  if test -s "$LOCKFILE"; then
    LOCKINGPID=`cat "$LOCKFILE" 2> /dev/null | sed 's/[\r\n ]//g'`
    if ps -eo pid,args | sed 's/^ *//' | egrep -qis "^$LOCKINGPID .*$PROGNAME"; then
      err_exit 11 "$0: An instance of $PROGNAME is already running (pid ${LOCKINGPID:-???}); aborting"
    fi
  fi
  if rm -f "$LOCKFILE"; then
    : hurray
  else
    rm -f "$TEMPLOCKFILE"
    err_exit 12 "$0: Can't remove lock file $LOCKFILE; please remove by hand!"
  fi
fi

if ln "$TEMPLOCKFILE" "$LOCKFILE"; then
  # echo "$0: Linked $TEMPLOCKFILE to $LOCKFILE"
  trap nixlockfile 1 2 3 15
else
  rm -f "$TEMPLOCKFILE"
  err_exit 13 "$0: An instance of $PROGNAME is already running; aborting"
fi
