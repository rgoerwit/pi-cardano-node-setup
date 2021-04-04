#!/bin/bash

err_exit() {
  EXITCODE=$1; shift
  (printf "$*" && echo -e "") 1>&2; 
  # pushd -0 >/dev/null && dirs -c
  exit $EXITCODE 
}

# Read in trapping and locking code, if present
SCRIPT_PATH=$(readlink -e "$0" | sed 's:/[^/]*$::' | tr -d '\r\n')
[ -z "$SCRIPT_PATH" ] && SCRIPT_PATH=$(dirname "$0" 2> /dev/null)
[ ".$SCRIPT_PATH" = '..' ] && SCRIPT_PATH=$(readlink -e ".")
if [ ".$SCRIPT_PATH" != '.' ] && [ -e "$SCRIPT_PATH/pi-cardano-node-fake-code.sh" ]; then
	. "$SCRIPT_PATH/pi-cardano-node-fake-code.sh" \
		|| err_exit 47 "$0: Can't execute $SCRIPT_PATH/pi-cardano-node-fake-code.sh"
fi

usage() {
  cat << _EOF 1>&2

Usage: $PROGNAME [-b <builduser>] [-d <device>] [-D] [-M <mountpoint>] [-u <install-user>]

Backs up current node configuration to another drive (-D <device>)

Examples:

$PROGNAME -D -d /dev/sda2 -u cardano

Arguments:

-b    Build user - user whose home is used to compile and stage executables
-d    Back setup up to device (defaults to /dev/sda2)
-D    Emit debugging messages
-M    Mount point for backup device (defaults to /mnt)
-u    User who will run the executables and in whose home directory the executables will be installed
_EOF
  exit 1
}

while getopts D: opt; do
    case "${opt}" in
        b ) BUILD_USER="${OPTARG}" ;;
        d ) BACKUP_DEVICE="${OPTARG}" ;;
        D ) DEBUG='Y' ;;
        M ) MOUNTPOINT="${OPTARG}" ;;
        u ) INSTALL_USER="${OPTARG}" ;;
        \? ) usage ;;
    esac
done

[ -z "${BUILD_USER}" ] && BUILD_USER='builduser'
[ -z "${BACKUP_DEVICE}" ] && BACKUP_DEVICE='/dev/sda2'
[ -z "${MOUNTPOINT}" ] && MOUNTPOINT='/mnt'
[ -z "${INSTALL_USER}" ] && INSTALL_USER='cardano'
INSTALLDIR="/home/${INSTALL_USER}"
BUILDDIR="/home/${BUILD_USER}/Cardano-BuildDir"
BUILDLOG="${TMPDIR:-/tmp}/build-log-$(date '+%Y-%m-%d-%H:%M:%S').log"
touch "$BUILDLOG"

if [ df | egrep -q "(^|[ \t])`echo $MOUNTPOINT | sed 's/\([.*[\^${}+?|()m]\)/\1/g'`($|[ \t])" ] \
    || [ df | egrep -q "(^|[ \t])`echo $BACKUP_DEVICE | sed 's/\([.*[\^${}+?|()m]\)/\1/g'`($|[ \t])" ]; then
    err_exit 8 "$0: Backup device or mountpoint already used or mounted (please run 'df'); aborting"
else
    mount "$BACKUP_DEVICE" "$MOUNTPOINT" \
        || err_exit 8 "$0: Unable to mount $BACKUP_DEVICE at $MOUNTPOINT; aborting"
fi 

# Redefine, now umounting filesystem
err_exit() {
  EXITCODE=$1; shift
  (printf "$*" && echo -e "") 1>&2; 
  # pushd -0 >/dev/null && dirs -c
  umount "$BACKUP_DEVICE"
  exit $EXITCODE 
}

# Sends output to console as well as the $BUILDLOG file
debug() {
	[ -z "$DEBUG" ] || echo -e "$@" | tee -a "$BUILDLOG" 
} 

skip_op() {	
	debug 'Skipping: ' "$@" 
}

debug "To monitor progress, run: tail -f \"$BUILDLOG\""

debug "Updating ${MOUNTPOINT}${BUILDDIR}"
rsync -av "${BUILDDIR}" "${MOUNTPOINT}/${BUILDDIR}" \
    err_exit 18 "$0: Unable rsync ${BUILDDIR} to ${MOUNTPOINT}${BUILDDIR}; aborting"
rsync -av "${INSTALLDIR}" "${MOUNTPOINT}/${INSTALLDIR}" \
    err_exit 19 "$0: Unable rsync ${INSTALLDIR} to ${MOUNTPOINT}${INSTALLDIR}; aborting"

# Read in trapping and locking code, if present
SCRIPT_PATH=$(readlink -e "$0" | sed 's:/[^/]*$::' | tr -d '\r\n')
[ -z "$SCRIPT_PATH" ] && SCRIPT_PATH=$(dirname "$0" 2> /dev/null)
[ ".$SCRIPT_PATH" = '..' ] && SCRIPT_PATH=$(readlink -e ".")
if [ ".$SCRIPT_PATH" != '.' ] && [ -e "$SCRIPT_PATH/pi-cardano-node-setup.sh" ]; then
	CARDANO_NODE_SETUP_SCRIPT="$SCRIPT_PATH/pi-cardano-node-setup.sh"
    HOMEDIR_OF_INSTALLUSER=$(getent passwd ${INSTALL_USER:-cardano} | cut -f6 -d:)
    LAST_COMPLETED_SETUP_COMMAND_FILE=$(ls -tR ${HOMEDIR_OF_INSTALLUSER}/logs/build-command-line-* | xargs egrep -l 'completed' | head -1)
    if [ ".$LAST_COMPLETED_SETUP_COMMAND_FILE" != '.' ] && [ -r "$LAST_COMPLETED_SETUP_COMMAND_FILE"]; then
        LAST_COMPLETED_SETUP_COMMAND=$(cat ".$LAST_COMPLETED_SETUP_COMMAND_FILE" | tr -d '\r\n' | sed 's/#.*$//')
        chroot "${MOUNTPOINT}" "exec ${LAST_COMPLETED_SETUP_COMMAND} -N"
    else   
        err_abort 9 "$0: Can't find or execute last-run command file, (${LAST_COMPLETED_SETUP_COMMAND_FILE:-unknown}); aborting"
    fi
    CARDANO_NODE_COMMANDS=''
fi

umount "${BACKUP_DEVICE}"
