#!/bin/bash
#
###############################################################################
#
#  Copyright 2021 Richard L. Goerwitz III
#
#    This code may be freely used for commercial or noncommercial purposes.
#    I make no guarantee, however, about this code's correctness or fitness
#    for any particular purpose.  Use it at your own risk.  For full licensing
#    information, see: https://github.com/rgoerwit/pi-cardano-node-setup/
#
###############################################################################
#
#  Used to back up a cardano-node running on a Raspberry Pi.  The
#  backup device is assumed to be a mountable filesystem (identified
#  by the -d <device> argument).  Typically this device will be the
#  second partition on an SD card, usually an an adapter, and visible
#  to the operating system as /dev/sda2
#
###############################################################################
#
#  Example:
#
#  ./pi-cardano-backup-to-chroot.sh -D -d /dev/sda2 \
#      -C 'pi-cardano-node-setup.sh -D -b builduser -u cardano -n mainnet \
#         -p 6001 -v 5 -s 192.168.1.0/24 \
#         -R relay-1.mydomain.net:3000,relay-2.mydomain.net:3000 \
#         -V 1.26.1'
#
###############################################################################

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

Usage: $PROGNAME [-b <builduser>] [-C <node-setup-command>] [-d <device>] [-D] [-M <mountpoint>] [-u <install-user>]

Backs up current node configuration to another drive (-D <device>)

Examples:

$PROGNAME -D -d /dev/sda2 -u cardano

Arguments:

-b    Build user - user whose home is used to compile and stage executables
-C    Command to supply to pi-cardano-node-setup.sh (usually not needed if just backing up; used if upgrading, for example; must include executable name)
-d    Back setup up to device
-D    Emit debugging messages
-M    Mount point for backup device (defaults to /mnt)
-u    User who will run the executables and in whose home directory the executables will be installed
_EOF
  exit 1
}

while getopts b:C:d:DM:u: opt; do
    case "${opt}" in
        b ) BUILD_USER="${OPTARG}" ;;
        C ) PI_CARDANO_NODE_SETUP_CMD="${OPTARG}" ;;
        d ) BACKUP_DEVICE="${OPTARG}" ;;
        D ) DEBUG='Y' ;;
        M ) MOUNTPOINT="${OPTARG}" ;;
        u ) INSTALL_USER="${OPTARG}" ;;
        \? ) usage ;;
    esac
done

[ -z "${BUILD_USER}" ] && BUILD_USER='builduser'
[ -z "${BACKUP_DEVICE}" ] && err_exit 17 "$0: Need to supply a -d <device>"
[ -z "${MOUNTPOINT}" ] && MOUNTPOINT='/mnt'
[ -z "${INSTALL_USER}" ] && INSTALL_USER='cardano'
INSTALLDIR="/home/${INSTALL_USER}"
BUILDDIR="/home/${BUILD_USER}/Cardano-BuildDir"
BUILDLOG="${TMPDIR:-/tmp}/build-log-$(date '+%Y-%m-%d-%H:%M:%S').log"
touch "$BUILDLOG"

if df | egrep -q "(^|[ \t])`echo $MOUNTPOINT | sed 's/\([.*[\^${}+?|()m]\)/\1/g'`($|[ \t])" \
    || df | egrep -q "(^|[ \t])`echo $BACKUP_DEVICE | sed 's/\([.*[\^${}+?|()m]\)/\1/g'`($|[ \t])"; then
    err_exit 8 "$0: Backup device or mountpoint already used or mounted (please run 'df'); aborting"
else
    mount "$BACKUP_DEVICE" "$MOUNTPOINT" \
        || err_exit 8 "$0: Unable to 'mount $BACKUP_DEVICE $MOUNTPOINT'; aborting"
fi 

# Redefine, now umounting filesystem
err_exit() {
    EXITCODE=$1; shift
    (printf "$*" && echo -e "") 1>&2; 
    # pushd -0 >/dev/null && dirs -c
    umount "$BACKUP_DEVICE"                                     2> /dev/null
    apt-mark unhold linux-image-generic linux-headers-generic   1> /dev/null 2>&1
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

debug "Creating ${MOUNTPOINT}${BUILDDIR}..."
mkdir -p "$MOUNTPOINT/$BUILDDIR"    1>> "$BUILDLOG" 2>&1
cd "${MOUNTPOINT}/${BUILDDIR}"      1>> "$BUILDLOG" 2>&1
[ -d 'pi-cardano-node-setup' ] \
    || git clone 'https://github.com/rgoerwit/pi-cardano-node-setup/' 1>> "$BUILDLOG" 2>&1
cd 'pi-cardano-node-setup'          1>> "$BUILDLOG" 2>&1
git reset --hard                    1>> "$BUILDLOG" 2>&1
git pull                            1>> "$BUILDLOG" 2>&1
cd "$BUILDDIR"

mkdir -p "${MOUNTPOINT}/home/${BUILD_USER}" 1>> "$BUILDLOG" 2>&1
debug "Syncing ${BUILDDIR} to ${MOUNTPOINT}/home/${BUILD_USER}"
rsync -av "${BUILDDIR}" "${MOUNTPOINT}/home/${BUILD_USER}" 1>> "$BUILDLOG" 2>&1 \
    || err_exit 18 "$0: Unable to rsync ${BUILDDIR} to ${MOUNTPOINT}/home/${BUILD_USER}; aborting"
debug "Syncing ${INSTALLDIR} to ${MOUNTPOINT}/home"
rsync -av "${INSTALLDIR}" "${MOUNTPOINT}/home" 1>> "$BUILDLOG" 2>&1 \
    || err_exit 19 "$0: Unable to rsync ${INSTALLDIR} to ${MOUNTPOINT}/home; aborting"
debug "Syncing /opt/cardano to ${MOUNTPOINT}/opt"
rsync -av "/opt/cardano" "${MOUNTPOINT}/opt" 1>> "$BUILDLOG" 2>&1 \
    || err_exit 20 "$0: Unable to rsync /opt/cardano to ${MOUNTPOINT}/opt; aborting"
cd /; find usr/local -depth -name 'libsodium*' -print | cpio -pdv /mnt 1>> "$BUILDLOG" 2>&1

debug "Ensuring resolver will work when we chroot"
if [ -L "/etc/resolv.conf" ]  && [[ ! -a "/etc/resolv.conf" ]]; then
    mkdir -p '/run/systemd/resolve'
    echo 'nameserver 1.1.1.1\nnameserver 8.8.8.8' >> "${MOUNTPOINT}/run/systemd/resolve/stub-resolv.conf"
fi

# Read in trapping and locking code, if present
SETUP_COMMAND="$PI_CARDANO_NODE_SETUP_CMD"
if [ -z "$SETUP_COMMAND" ]; then 
    debug "No -C <command> supplied; using last-used, completed pi-cardano-node-setup.sh command"
    HOMEDIR_OF_INSTALLUSER=$(getent passwd ${INSTALL_USER:-cardano} | cut -f6 -d:)
    LAST_COMPLETED_SETUP_COMMAND_FILE=$(ls -tR ${HOMEDIR_OF_INSTALLUSER}/logs/build-command-line-* | xargs egrep -l 'completed' | head -1)
    LAST_COMPLETED_SETUP_COMMAND=$(cat "$LAST_COMPLETED_SETUP_COMMAND_FILE" | tr -d '\r\n' | sed 's/#.*$//')
fi
if [ -z "$SETUP_COMMAND" ]; then
    err_abort 9 "$0: No -C <command> supplied and can't find last pi-cardano-node-setup.sh command-line; aborting"
else
    # Strip out path and executable name, but keep arguments; replace with latest downloade above
    SETUP_COMMAND=$(echo "$SETUP_COMMAND" | sed 's/^[ \t]*pi-[^ \t]*[ \t][ \t]*//' | sed 's/[ \t]*-N[ \t]*$//') # strip executable and -N
    SETUP_COMMAND="${BUILDDIR}/pi-cardano-node-setup/scripts/pi-cardano-node-setup.sh ${SETUP_COMMAND} -N"
fi

debug "Running setup script in chroot (with -N argument) on $BACKUP_DEVICE:\n    ${SETUP_COMMAND}"
chroot "${MOUNTPOINT}" /bin/bash -v << _EOF
trap "umount /proc" SIGTERM SIGINT  # Make sure /proc gets unmounted, else we might freeze
mount -t proc proc /proc            1>> /dev/null
apt-mark hold linux-image-generic linux-headers-generic cryptsetup-initramfs flash-kernel flash-kernel:arm64    1>> /dev/null
bash -c "bash $SETUP_COMMAND"
apt-mark unhold linux-image-generic linux-headers-generic cryptsetup-initramfs flash-kernel flash-kernel:arm64  1>> /dev/null
umount /proc                        1>> /dev/null
_EOF

cd "$SCRIPT_PATH"           1>> "$BUILDLOG" 2>&1
umount "${BACKUP_DEVICE}"   1>> "$BUILDLOG" 2>&1
