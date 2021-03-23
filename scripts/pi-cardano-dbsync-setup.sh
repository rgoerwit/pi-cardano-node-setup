#!/bin/bash
#
#############################################################################
#
#  Meant to be sourced by pi-cardano-node-setup.sh
#
#############################################################################

[ -z "${INSTALL_USER}" ]      && INSTALL_USER='cardano'
[ -z "${INSTALLDIR}" ]        && INSTALLDIR="/home/${INSTALL_USER}"
[ -z "${BUILD_USER}" ]        && BUILD_USER='builduser'
[ -z "${BUILDDIR}" ]          && BUILDDIR="/home/${BUILD_USER}/Cardano-BuildDir"
[ -z "${BUILDLOG}" ]          && BUILDLOG="${BUILDDIR}/cardano-db-sync/build-$(date '+%Y-%m-%d-%H:%M:%S').log"
[ -z "${CARDANO_FILEDIR}" ]   && CARDANO_FILEDIR="${INSTALLDIR}/files"
[ -z "${CARDANO_SCRIPTDIR}" ] && CARDANO_SCRIPTDIR="${INSTALLDIR}/scripts"
[ -z "${GUILDREPO_RAW_URL}" ] && GUILDREPO_RAW_URL="https://raw.githubusercontent.com/cardano-community/guild-operators/${GUILDREPOBRANCH}"
[ -z "${IOHKREPO}" ]          && IOHKREPO="https://github.com/input-output-hk/"
[ -z "${IOHKAPIREPO}" ]       && IOHKAPIREPO="https://api.github.com/repos/input-output-hk"
[ -z "${CABAL_EXECUTABLE}" ]  && CABAL_EXECUTABLE="cabal"
[ -z "${WGET}" ]              && WGET="wget"
[ -z "${APTINSTALLER}" ]      && APTINSTALLER="apt-get -q --assume-yes"

PROJECTNAME='cardano-db-sync'

if declare -F debug 1> /dev/null; then
	: do nothing
else
debug() {
	[ -z "$DEBUG" ] || echo -e "$@" | tee -a "$BUILDLOG" 
} 
fi

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

$APTINSTALLER install postgresql libpq-dev 1>> "$BUILDLOG" 2>&1 \
	|| err_exit 72 "$0: Failed to install postgresql; aborting"
systemctl enable postgresql 1>> "$BUILDLOG" 2>&1 \\
    || err_exit 81 "$0: Failed to enable postgresql service ('systemctl enable postgresql'); aborting"

only do this if database is not yet created...
hostname:port:database:username:password



export PGPASSFILE="${BUILDDIR}/${PROJECTNAME}/config/pgpass"
echo "root:$(strings /dev/urandom | grep -o '[[:alnum:]]' | head -n 16 | tr -d '\n'; echo):cardanodata" > "$PGPPASSFILE"
su -u "$INSTALL_USER" -c "createuser --createdb --superuser $user"
chmod go-rwx "$PGPPASSFILE"




cd "${BUILDDIR}"
if [ -d "${BUILDDIR}/${PROJECTNAME}" ]; then
    : nothing to do 
else
    git clone "${IOHKREPO}/${PROJECTNAME}" 1>> "$BUILDLOG" 2>&1 \
        || err_exit 73 "$0:  Failed to clone repository: ${IOHKREPO}/${PROJECTNAME}"
fi
cd "${BUILDDIR}/${PROJECTNAME}"

git fetch --tags --all 1>> "$BUILDLOG" 2>&1
git pull               1>> "$BUILDLOG" 2>&1 \
    err_exit 74 "$0:  Failed to pull latest code for ${PROJECTNAME}"

# Include the cardano-crypto-praos and libsodium components for db-sync
# On CentOS 7 (GCC 4.8.5) we should also do
# echo -e "package cryptonite\n  flags: -use_target_attributes" >> cabal.project.local
echo -e "package cardano-crypto-praos\n flags: -external-libsodium-vrf" > cabal.project.local

# Replace tag against checkout if you do not want to build the latest released version
DBSYNC_LATEST_VERSION=$(curl -s "${IOHKAPIREPO}/${PROJECTNAME}/releases/latest" | jq -r .tag_name)
debug "Inferred latest version of ${PROJECTNAME}: $DBSYNC_LATEST_VERSION"
git checkout "$DBSYNC_LATEST_VERSION" 1>> "$BUILDLOG" 2>&1 \
    || err_exit 77 "$0: Failed to checkout ${PROJECTNAME}, version $DBSYNC_LATEST_VERSION"

debug "Overwriting cabal.project.local with latest file from guild-repo (previous file, if any, will be saved as cabal.project.local.swp)"
[[ -f cabal.project.local ]] && mv cabal.project.local cabal.project.local.swp
CABAL_PROJECT_LOCAL_URL="${GUILDREPO_RAW_URL}/files/cabal.project.local"
$WGET --quiet --continue -O cabal.project.local "${CABAL_PROJECT_LOCAL_URL}"
chmod 640 cabal.project.local

debug "Running cabal update to ensure you're on latest dependencies.."
$CABAL_EXECUTABLE update     1>> "$BUILDLOG" 2>&1
$CABAL_EXECUTABLE build all  1>> "$BUILDLOG" 2>&1
$CABAL_EXECUTABLE install --installdir "$INSTALLDIR" 1>> "$BUILDLOG" 2>&1

cd "${BUILDDIR}/${PROJECTNAME}"
if [ -f "${INSTALLDIR}/cardano-db-sync-isConfigured.txt" ]; then
    debug "PostgreSQL is already set up; skipping setup: ${BUILDDIR}/${PROJECTNAME}/scripts/postgresql-setup.sh --createdb"
else
    debug "Initializing PostgreSQL databases"
    scripts/postgresql-setup.sh --createdb &&
        echo "$(date)" >> "${INSTALLDIR}/cardano-db-sync-isConfigured.txt"
fi

DBSYNCSTARTUPSCRIPT="/lib/systemd/system/cardano-db-sync.service"
cat << _EOF > "$DBSYNCSTARTUPSCRIPT"
# Make sure cardano-db-sync is installed as a service
[Unit]
Description=cardano-db-sync start script
After=cardano-db-sync.service
 
[Service]
User=$INSTALL_USER
Environment=LD_LIBRARY_PATH=/usr/local/lib
KillSignal=SIGINT
RestartKillSignal=SIGINT
StandardOutput=journal
StandardError=journal
SyslogIdentifier=cardano-db-sync
TimeoutStartSec=0
Type=simple
KillMode=process
WorkingDirectory=$INSTALLDIR
ExecStart=$INSTALLDIR/cardano-db-sync-extended --config $CARDANO_FILEDIR/dbsync.json --socket-path $INSTALLDIR/sockets/core-node.socket --state-dir $INSTALLDIR/guild-db/ledger-state --schema-dir schema/
Restart=on-failure
RestartSec=12s
LimitNOFILE=32768
 
[Install]
WantedBy=multi-user.target

_EOF
	chown root.root "$DBSYNCSTARTUPSCRIPT"
	chmod 0644 "$DBSYNCSTARTUPSCRIPT"
fi
debug "$INSTALLDIR/cardano-db-sync-extended \\
    --config $CARDANO_FILEDIR/dbsync.json \\
    --socket-path $INSTALLDIR/sockets/core-node.socket \\
    --state-dir $INSTALLDIR/guild-db/ledger-state \\
    --schema-dir schema/"

debug "Setting up cardano-db-sync as system service"
systemctl daemon-reload	
systemctl enable cardano-db-sync 1>> "$BUILDLOG" 2>&1
systemctl start cardano-db-sync  1>> "$BUILDLOG" 2>&1
(systemctl status cardano-db-sync | tee -a "$BUILDLOG" 2>&1 | egrep -q 'ctive.*unning') \
    || err_exit 138 "$0: Problem enabling (or starting) cardano-db-sync service; aborting (run 'systemctl status cardano-db-sync')"
