#!/bin/bash
#
#############################################################################
#
#  Meant to be sourced by pi-cardano-node-setup.sh
#
#############################################################################


[ -z "${BLOCKCHAINNETWORK}" ] && BLOCKCHAINNETWORK='mainnet'
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
[ -z "${MY_SSH_HOST}" ]       && MY_SSH_HOST=$(netstat -an | sed -n 's/^.*:22[[:space:]]*\([1-9][0-9.]*\):[0-9]*[[:space:]]*\(LISTEN\|ESTABLISHED\) *$/\1/gip' | sed 's/[[:space:]]/,/g')
[ -z "$MY_SSH_HOST" ] || MY_SUBNETS="$MY_SUBNETS,$MY_SSH_HOST"

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

debug "Overwriting cabal.project.local w/ latest from guild-repo (previous saved as cabal.project.local.swp)"
[[ -f cabal.project.local ]] && mv cabal.project.local cabal.project.local.swp
CABAL_PROJECT_LOCAL_URL="${GUILDREPO_RAW_URL}/files/cabal.project.local"
$WGET --quiet --continue -O cabal.project.local "${CABAL_PROJECT_LOCAL_URL}"
chmod 640 cabal.project.local

debug "Running 'cabal update' to ensure we have latest dependencies"
$CABAL_EXECUTABLE update     1>> "$BUILDLOG" 2>&1
$CABAL_EXECUTABLE build all  1>> "$BUILDLOG" 2>&1

# Stop db-sync service and disable, to allow us to recreate database and startup script
systemctl stop cardano-db-sync      1>> "$BUILDLOG" 2>&1
systemctl disable cardano-db-sync   1>> "$BUILDLOG" 2>&1

$CABAL_EXECUTABLE install --installdir "$INSTALLDIR" 1>> "$BUILDLOG" 2>&1
if [ -x "$INSTALLDIR/${PROJECTNAME}-extended" ]; then
    : do nothing
else
    cp $(find "$BUILDDIR/${PROJECTNAME}" -type f -name ${PROJECTNAME} ! -path '*OLD*') "$INSTALLDIR/${PROJECTNAME}"
    cp $(find "$BUILDDIR/${PROJECTNAME}" -type f -name ${PROJECTNAME}-extended ! -path '*OLD*') "$INSTALLDIR/${PROJECTNAME}-extended"
fi

debug "Making sure PostgreSQL is installed, enabled, and started"
$APTINSTALLER install postgresql libpq-dev  1>> "$BUILDLOG" 2>&1 \
    || err_exit 72 "$0: Failed to install postgresql; aborting"
systemctl enable postgresql                 1>> "$BUILDLOG" 2>&1
service postgresql start                    1>> "$BUILDLOG" 2>&1 
(systemctl status postgresql | tee -a "$BUILDLOG" 2>&1 | egrep -q 'ctive ') \
    || err_exit 138 "$0: Problem enabling (or starting) postgresql service; aborting (run 'systemctl status postgresql')"

PSQLVERSION=$(psql --version | sed 's/^.* \([0-9]*[0-9]\.[0-9][0-9]*\) .*$/\1/')
PSQLSUBVERSION=$(psql --version | sed 's/^.* \([0-9]*[0-9]\)\.[0-9][0-9]* .*$/\1/')
PGHBA_FILE="/etc/postgresql/${PSQLVERSION}/main/pg_hba.conf"
PGCONF_FILE="/etc/postgresql/${PSQLVERSION}/main/postgresql.conf"  # #listen_addresses = 'localhost'
[ -f "/etc/postgresql/${PSQLSUBVERSION}/main/pg_hba.conf" ]     && PGHBA_FILE="/etc/postgresql/${PSQLSUBVERSION}/main/pg_hba.conf"
[ -f "/etc/postgresql/${PSQLSUBVERSION}/main/postgresql.conf" ] && PGCONF_FILE="/etc/postgresql/${PSQLSUBVERSION}/main/postgresql.conf"
sed -i "s/^[[:space:]]*#[[:space:]]*listen_addresses[[:space:]]*=[[:space:]]*'localhost'/listen_addresses='*'/" "$PGCONF_FILE" # listen on all interfaces
for NETW in $(echo "$MY_SUBNETS" | sed 's/ *, */ /g'); do
    [ -z "$NETW" ] && next
    MYMASK='/32' # assume IPv4 until proven otherwise
    if (echo "$NETW" | egrep -q '/[0-9]+'); then
        : do nothing
    else
        # PostgreSQL insists in its pg_hba.conf file that we use only networks, no hosts (e.g., xxx.xxx.xxx.xxx/xxx)
        (echo "$NETW" | egrep -q ':') && MYMASK='/128' # IPv6
        NETW="${NETW}${MYMASK}"
    fi
    # if pghba file lacks a line for this NETWork, add it to the end
    if egrep -q "^[[:space:]]*host[[:space:]]*all[[:space:]]*all[[:space:]]*$NETW[[:space:]]*md5[[:space:]]*$" "$PGHBA_FILE"; then
        debug "Line for remote cardano user, via $NETW, is already present in $PGHBA_FILE"
    else
        debug "Adding line for remote cardano user, via $NETW, to $PGHBA_FILE"
        echo "host    all             all             $NETW            md5" >> "$PGHBA_FILE"
    fi
    if egrep -q "^[[:space:]]*local[[:space:]]*all[[:space:]]*cardano[[:space:]]*peer[[:space:]]*$" "$PGHBA_FILE"; then
        debug "Line for local cardano user is already present in $PGHBA_FILE"
    else
        debug "Adding line for local cardano user to $PGHBA_FILE"
        echo "local   all             cardano                                peer" >> "$PGHBA_FILE"
    fi
done
service postgresql restart                  1>> "$BUILDLOG" 2>&1 \
    || err_exit 138 "$0: Problem restarting) postgresql service; aborting (run 'systemctl status postgresql')"

cd "${BUILDDIR}/${PROJECTNAME}"
WHENLASTUPDATED_FILE="${INSTALLDIR}/${PROJECTNAME}/${BLOCKCHAINNETWORK}-cardano-db-sync-isConfigured.txt"
PGPASSFILE="${INSTALLDIR}/${PROJECTNAME}/config/${BLOCKCHAINNETWORK}-pgpass" # https://www.postgresql.org/docs/current/libpq-pgpass.html

for subdir in 'config' 'schema'; do
    mkdir -p "${INSTALLDIR}/${PROJECTNAME}/${subdir}" 1>> "$BUILDLOG" 2>&1
    if [ "$subdir" = 'schema' ]; then
        cp -R "${BUILDDIR}/${PROJECTNAME}/${subdir}/"* "${INSTALLDIR}/${PROJECTNAME}/${subdir}"
    fi
    chown -R "${INSTALL_USER}.${INSTALL_USER}" "${INSTALLDIR}/${PROJECTNAME}/${subdir}" 2> /dev/null
    find "${INSTALLDIR}/${PROJECTNAME}/${subdir}" -type d -exec chmod "2775" {} \;
done

if [ ".$DONT_OVERWRITE" != 'Y' ]; then
    debug "Reconfiguring PostgreSQL database; last set up on $(cat $WHENLASTUPDATED_FILE)"

    if [ -f "$PGPASSFILE" ]; then
        echo "Remote PostgreSQL password for $BUILD_USER is: $(cut -d : -f 5 $PGPASSFILE)" | tee -a "$BUILDLOG"
    else
        debug "Creating new pgpass file: $PGPASSFILE"
        CARDANOPASS=$(strings /dev/urandom | grep -o '[[:alnum:]]' | head -n 16 | tr -d '\n'; echo)
        echo "/var/run/postgresql:5432:cexplorer:${INSTALL_USER}:${CARDANOPASS}" > "$PGPASSFILE"
        chmod go-rwx "$PGPASSFILE"
        echo "Remote PostgreSQL password for $BUILD_USER is: ${CARDANOPASS}" | tee -a "$BUILDLOG"
    fi

    debug "Initializing PostgreSQL databases: ${BUILDDIR}/${PROJECTNAME}/scripts/postgresql-setup.sh --createdb"
    sudo -u "postgres" createuser --createdb --superuser "$(whoami)"    1>> "$BUILDLOG" 2>&1
    dropuser "$INSTALL_USER"                                            1>> "$BUILDLOG" 2>&1
    createuser --login "$INSTALL_USER"                                  1>> "$BUILDLOG" 2>&1
    echo "ALTER ROLE cardano WITH PASSWORD '82B7GU2IKgrMd9O7';" | psql cexplorer 1> /dev/null

    export PGPASSFILE
    scripts/postgresql-setup.sh --dropdb    1>> "$BUILDLOG" 2>&1
    scripts/postgresql-setup.sh --createdb  1>> "$BUILDLOG" 2>&1 \
        || err_exit 83 "$0: Failed to configure PostgreSQL database (Guild postgresql-setup.sh script); aborting"
    echo -n "$(date)" > "$WHENLASTUPDATED_FILE"
fi

DBSYNCSTARTUPSCRIPT="/lib/systemd/system/cardano-db-sync.service"
cat << _EOF > "$DBSYNCSTARTUPSCRIPT"
# Make sure cardano-db-sync is installed as a service
[Unit]
Description=cardano-db-sync start script
Requires=postgresql.service
After=cardano-node.service
 
[Service]
User=$INSTALL_USER
Environment=LD_LIBRARY_PATH=/usr/local/lib
Environment=PGPASSFILE=$PGPASSFILE
KillSignal=SIGINT
RestartKillSignal=SIGINT
StandardOutput=journal
StandardError=journal
SyslogIdentifier=cardano-db-sync
TimeoutStartSec=0
Type=simple
KillMode=process
WorkingDirectory=$INSTALLDIR/${PROJECTNAME}
ExecStart=$INSTALLDIR/${PROJECTNAME}-extended --config $CARDANO_FILEDIR/dbsync.json --socket-path $INSTALLDIR/sockets/core-node.socket --state-dir $INSTALLDIR/guild-db/ledger-state --schema-dir schema/
Restart=on-failure
RestartSec=10s
LimitNOFILE=32768
 
[Install]
WantedBy=multi-user.target

_EOF
chown root.root "$DBSYNCSTARTUPSCRIPT"
chmod 0644 "$DBSYNCSTARTUPSCRIPT"

debug "$INSTALLDIR/${PROJECTNAME}-extended \\
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
