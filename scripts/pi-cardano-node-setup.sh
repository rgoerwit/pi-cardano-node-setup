#!/bin/bash
#
###############################################################################
#
#  Copyright 2021 Richard L. Goerwitz III
#
#  This code may be freely used for commercial or noncommercial purposes.
#  I make no guarantee, however, about this code's correctness or fitness
#  for any particular purpose.  Use it at your own risk.  For full licensing
#  information, see: https://github.com/rgoerwit/pi-cardano-node-setup/
#
############################################################################### 
#
#  Builds cardano-node and friends on a Raspberry Pi running Ubuntu LTS.
#
#  Keeps everything as simple as possible - no extra layers of memory or
#  swap management, no Docker images or dockerfiles, no Ansible playbooks,
#  or much of anything beyond what can be accomplished with shell scripts.
#
#  Compiles everything possible from scratch, avoids third-party shell 
#  scripts pulled live off of external sites.  Works with CNTools, sorta,
#  but changes permissions on a number of files, and creates separate
#  users for services being run (instead of running them as the current
#  user or, worse yet, root).  Builds node_exporter and enables Cardano
#  Prometheus data, but hides these behind a private Prometheus instance
#  that is, in turn, reverse-proxied by nginx.  Sets a password and TLS
#  for nginx, to make it possible to monitor with hosted Grafana services
#  in the cloud.
#
#  This script is something I use for my own purposes.  I assume people
#  who run it know their way around a Linux box.  YMMV.
#
###############################################################################
#

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

Usage A: $PROGNAME [-4 <bind IPv4>] [-6 <bind IPv6>] [-b <builduser>] [-B <guild repo branch name>] [-c <node config filename>] \
    [-C <cabal version>] [-d] [-D] [-f <parent:port>] [-F <hostname>] [-g <GHC-OS>] [-G <GCC-arch] [-h <SID:password>] [-H] [-i] [-m <seconds>] \
	[-n <mainnet|testnet|launchpad|guild|staging>] [-N] [-o <overclock speed>] [-p <port>] [-P <pool name>] [-r]  [-R <node-ip:port>] \
	[-s <subnet>] [-S] [-u <installuser>] [-w <libsodium-version-number>] [-U <cardano-node branch>] [-v <VLAN num> ] \
	[-V <cardano-node version>] [-w <libsodium-version>] [-w <cnode-script-version>] [-x] [-y <ghc-version>] [-Y]

Usage B: $PROGNAME -l -u <installuser>   # To see what you last did

Sets up a Cardano node on a new Pi 4 running Ubuntu LTS distro

Examples:

New (overclocking) mainnet setup on TCP port 3000:   $PROGNAME -D -b builduser -u cardano -n mainnet -o 2100 -p 3000  
Refresh of existing mainnet setup (keep existing config files):  $PROGNAME -D -d -b builduser -u cardano -n mainnet

-4    Bind IPv4 address (defaults to 0.0.0.0)
-6    Bind IPv6 address (defaults to NULL)
-b    User whose home directory will be used for compiling (defaults to 'builduser')
-B    Branch to use when checking out SPO Guild repo code (defaults to 'master')
-c    Node configuration file (defaults to <install user home dir>/<network>-config.json)
-C    Specific cabal version to use
-d    Don't overwrite config files, or 'env' file for gLiveView
-D    Emit chatty debugging output about what the program is doing
-f    Configure as a warm-spare failover for server <parent:port> (may be a DNS name or IP address)
-F    Force <hostname> as external DNS name (mainly relevant if using hosted Grafana and you're on dynamic DNS)
-g    GHC operating system (defaults to deb10; could also be deb9, centos7, etc.)
-G    GHC gcc architecture (default is -march=Armv8-A); the value here is in the form of a flag supplied to GCC
-y    GHC version (currently defaults to 8.10.4)
-h    Install (naturally, hidden) WiFi; format: SID:password (only use WiFi on the relay, not block producer)
-H    Hosted Grafana - allow appropriate access to Prometheus port (may require further ACLs or port forwarding)
-i    Ignore missing dependencies installed by apt-get
-l    Print command-line used for last run and exit
-m    Maximum time in seconds that you allow the file download operation to take before aborting (Default: 80s)
-n    Connect to specified network instead of mainnet network (Default: mainnet)
      e.g.: -n testnet (alternatives: allegra launchpad mainnet mary_qa shelley_qa staging testnet...)
-N    No startup - don't start cardano-node or other services (used for backups to /dev/sda...)
-o    Overclocking value (should be something like, e.g., 2100 for a Pi 4 - with heat sinks and a fan, should be fine)
-p    Listen port (default 3000); assumes we are a block producer if <port> is >= 6000
-P    Pool name (not ticker - useful if using CNTools to create wallets inside <INSTALLDIR>/priv/pool)
-r    Install RDP
-R    Nodes (ip-address:port[,ip-address:port...]) to add to topology.json file (to point relays at BP and vice versa)
-s    Networks to allow SSH from (comma-separated, CIDR)
-S    Skip firewall configuration
-u    User who will run the executables and in whose home directory the executables will be installed
-U    Specify Cardano branch to check out (goes with -V <version>; usually the value will be 'master' or 'bench')
-w    Specify a libsodium version (defaults to the wacky version the Cardano project recommends)
-W    Specify a Guild CNode Tool version (defaults to the latest)
-v    Enable vlan <number> on eth0; DHCP to that VLAN; disable eth0 interface
-V    Specify Cardano node version (for example, 1.25.1; defaults to a recent, stable version); compare -U <branch>
-x    Don't recompile anything big, like ghc, libsodium, and cardano-node
-Y    Set up cardano-db-sync
_EOF
  exit 1
}

while getopts 4:6:b:B:c:C:dDf:F:g:G:h:Hilm:n:No:p:P:rR:s:Su:U:v:V:w:W:xy:Y opt; do
  case "${opt}" in
    '4' ) IPV4_ADDRESS="${OPTARG}" ;;
    '6' ) IPV6_ADDRESS="${OPTARG}" ;;
	b ) BUILD_USER="${OPTARG}" ;;
	B ) GUILDREPOBRANCH="${OPTARG}" ;;
	c ) NODE_CONFIG_FILE="${OPTARG}" ;;
	C ) CABAL_VERSION="${OPTARG}" ;;
	d ) DONT_OVERWRITE='Y' ;;
	D ) DEBUG='Y' ;;
	f ) FAILOVER_PARENT="${OPTARG}" ;;
	F ) EXTERNAL_HOSTNAME="${OPTARG}" ;;
	g ) GHCOS="${OPTARG}" ;;
	G ) GHC_GCC_ARCH="${OPTARG}" ;;
	y ) GHCVERSION="${OPTARG}" ;;
    h ) HIDDEN_WIFI_INFO="${OPTARG}" ;;
	H ) HOSTED_GRAFANA='Y' ;;
	i ) IGNORE_MISSING_DEPENDENCIES='--ignore-missing' ;;
	l ) PRINT_LAST_CMDLINE='Y' ;;
    m ) WGET_TIMEOUT="${OPTARG}" ;;
    n ) BLOCKCHAINNETWORK="${OPTARG}" ;;
    N ) START_SERVICES="N" ;;
	o ) OVERCLOCK_SPEED="${OPTARG}" ;;
    p ) LISTENPORT="${OPTARG}" ;;
    P ) POOLNAME="${OPTARG}" ;;
    r ) INSTALLRDP='Y' ;;
	R ) NODE_INFO="${OPTARG}" ;; 
	s ) MY_SUBNETS="${OPTARG}" ;;
	S ) SKIP_FIREWALL_CONFIG='Y' ;;
    u ) INSTALL_USER="${OPTARG}" ;;
	U ) CARDANOBRANCH="${OPTARG}" ;;
	v ) VLAN_NUMBER="${OPTARG}" ;;
	V ) CARDANONODE_VERSION="${OPTARG}" ;;
    w ) LIBSODIUM_VERSION="${OPTARG}" ;;
    W ) GUILDSCRIPT_VERSION="${OPTARG}" ;;
    x ) SKIP_RECOMPILE='Y' ;;
    Y ) SETUP_DBSYNC='Y' ;;
    \? ) usage ;;
    esac
done

APTINSTALLER="apt-get -q --assume-yes $IGNORE_MISSING_DEPENDENCIES"  # could also be "apt --assume-yes" or for other distros, "yum -y"
if $APTINSTALLER install net-tools 1>> /dev/null 2>&1 \
	&& $APTINSTALLER install dnsutils 1>> /dev/null 2>&1
then
	: yay 
else
	ischroot && find /etc -maxdepth 1 -xtype l -exec 'rm' -f {} \; 1>> /dev/null 2>&1
	egrep -q '^nameserver 1\.1\.1\.1' /etc/resolv.conf 1>> /dev/null 2>&1 \
		|| echo -e "nameserver 1.1.1.1\nnameserver 8.8.8.8" >> /etc/resolv.conf
	$APTINSTALLER update --fix-missing	1>> /dev/null 2>&1
	$APTINSTALLER install net-tools		1>> /dev/null 2>&1
	$APTINSTALLER install dnsutils		1>> /dev/null 2>&1
fi
[ -z "${IPV4_ADDRESS}" ] && IPV4_ADDRESS='0.0.0.0'	2> /dev/null
APPARENT_IPV6_ADDRESS=$(dig +timeout=5 +short -6 myip.opendns.com aaaa @resolver1.ipv6-sandbox.opendns.com 2> /dev/null | egrep -v '^;;' | tr -d '\r\n ') 2> /dev/null
if [ -z "$APPARENT_IPV6_ADDRESS" ]; then
	# IPv6 connectivity appears to be unavailable; using IPv4 only
	IPV6_ADDRESS=
else
	# We really ought to check if the apparent address is local; it won't be if we're behind NAT
	[ -z "${IPV6_ADDRESS}" ] && IPV6_ADDRESS="$APPARENT_IPV6_ADDRESS"
	# [ -z "${IPV6_ADDRESS}" ] && '::/0'  # Listen on all IPv6 interfaces - seems not to be parsed right by cardano-node
fi
[ -z "${EXTERNAL_IPV4_ADDRESS}" ] && EXTERNAL_IPV4_ADDRESS="$(dig +timeout=5 +short myip.opendns.com @resolver1.opendns.com 2> /dev/null | egrep -v '^;;' | tr -d '\r\n ')" 2> /dev/null
[ -z "${EXTERNAL_IPV4_ADDRESS}" ] && EXTERNAL_IPV4_ADDRESS="$(host -4 myip.opendns.com resolver1.opendns.com 2> /dev/null | tail -1 | awk '{ print $(NF) }')" 2> /dev/null
[ -z "${EXTERNAL_IPV6_ADDRESS}" ] && EXTERNAL_IPV6_ADDRESS="$(dig +timeout=5 +short -6 myip.opendns.com aaaa @resolver1.ipv6-sandbox.opendns.com 2> /dev/null | egrep -v '^;;' | tr -d '\r\n ')" 2> /dev/null
[ -z "${EXTERNAL_IPV6_ADDRESS}" ] && EXTERNAL_IPV6_ADDRESS="$(host -6 myip.opendns.com resolver1.opendns.com 2> /dev/null | tail -1 | awk '{ print $(NF) }')" 2> /dev/null
[ -z "${EXTERNAL_HOSTNAME}" ] && EXTERNAL_HOSTNAME=$(dig +noall +answer +short -x "${EXTERNAL_IPV4_ADDRESS}" 2> /dev/null | sed 's/\.$//')
[ -z "${EXTERNAL_HOSTNAME}" ] && EXTERNAL_HOSTNAME=$(dig +noall +answer +short -x "${EXTERNAL_IPV6_ADDRESS}" 2> /dev/null | sed 's/\.$//')
[ -z "${EXTERNAL_HOSTNAME}" ] && EXTERNAL_HOSTNAME="${EXTERNAL_IPV4_ADDRESS}"
[ -z "${EXTERNAL_HOSTNAME}" ] && EXTERNAL_HOSTNAME="${EXTERNAL_IPV6_ADDRESS}"
MY_SUBNET=$(echo "$MY_SUBNET"	| tr -d ' 	\r')
NODE_INFO=$(echo "$NODE_INFO"	| tr -d ' 	\r')
[ -z "${MY_SUBNET}" ] && MY_SUBNET=$(ip addr | awk '/^ *inet / { print $2 }' | tail -1)  # With a Pi, you get just one RJ45 jack; take best guess at local subnet
[ -z "${MY_SUBNET}" ] && MY_SUBNET=$(ip addr | egrep -v 'fe80|::[10]/(128|0)' | awk '/^ *inet6 / { print $2 }' | tail -1)  # Again, best guess here
if [ -z "${MY_SUBNETS}" ]; then
	MY_SUBNETS="$MY_SUBNET"
else
    if echo "$MY_SUBNETS" | egrep -qv "$(echo \"$MY_SUBNET\" | sed 's/\./\\./g')"; then
		# Make sure that the active interface's network is present in $MY_SUBNETS
		MY_SUBNETS="$MY_SUBNETS,$MY_SUBNET"
	fi
fi
MY_SSH_HOST=$(netstat -an | sed -n 's/^.*:22[[:space:]]*\([1-9][0-9.]*\):[0-9]*[[:space:]]*\(LISTEN\|ESTABLISHED\) *$/\1/gip' | sed 's/[[:space:]]/,/g')
[ -z "$MY_SSH_HOST" ] || MY_SUBNETS="$MY_SUBNETS,$MY_SSH_HOST"  # Make sure not to cut off the current SSH session
[ -z "${BUILD_USER}" ] && BUILD_USER='builduser'
[ -z "${WGET_TIMEOUT}" ] && WGET_TIMEOUT=80
[ -z "${BLOCKCHAINNETWORK}" ] && BLOCKCHAINNETWORK='mainnet'
[ -z "${LISTENPORT}" ] && LISTENPORT='3000'
[ -z "${INSTALLRDP}" ] && INSTALLRDP='N'
[ -z "${INSTALL_USER}" ] && INSTALL_USER='cardano'
[ -z "${SUDO}" ] && SUDO='Y'
[ -z "$LIBSODIUM_VERSION" ] && LIBSODIUM_VERSION='66f017f1'
[ -z "$PREPROXY_PROMETHEUS_PORT" ] && PREPROXY_PROMETHEUS_PORT=9089
[ -z "$PREPROXY_PROMETHEUS_LISTEN" ] && PREPROXY_PROMETHEUS_LISTEN="${IPV4_ADDRESS:-$IPV6_ADDRESS}"
[ -z "$EXTERNAL_PROMETHEUS_PORT" ] && EXTERNAL_PROMETHEUS_PORT=$( expr "$PREPROXY_PROMETHEUS_PORT" + 1 )	# The order matters here
EXTERNAL_NODE_EXPORTER_PORT=$(expr "$EXTERNAL_PROMETHEUS_PORT" + 1 )										# The order matters here
EXTERNAL_NODE_EXPORTER_LISTEN='127.0.0.1'
CARDANO_PROMETHEUS_PORT=12798       	# Port where cardano-node provides data TO prometheus (not actual prometheus port)
CARDANO_PROMETHEUS_LISTEN='0.0.0.0' 	# IP address where cardano-node provides data TO prometheus; could be 127.0.0.1 (but can't check that easily)
INSTALLDIR="/home/${INSTALL_USER}"
BUILDDIR="/home/${BUILD_USER}/Cardano-BuildDir"
BUILDLOG="${TMPDIR:-/tmp}/build-log-$(date '+%Y-%m-%d-%H:%M:%S').log"
touch "$BUILDLOG"; chmod o-rwx "$BUILDLOG"
CARDANO_DBDIR="${INSTALLDIR}/db-${BLOCKCHAINNETWORK}"
CARDANO_PRIVDIR="${INSTALLDIR}/priv-${BLOCKCHAINNETWORK}"
CARDANO_FILEDIR="${INSTALLDIR}/files"
CARDANO_SCRIPTDIR="${INSTALLDIR}/scripts"					# mostly guild scripts
CARDANO_SPOSDIR="${INSTALLDIR}/spos-${BLOCKCHAINNETWORK}"	# SPOS scripts ("Martin's scripts")

# Make sure the path has the locations in it that we'll be needing
( [[ "$PATH" =~ /usr/local/bin ]] && [[ "$PATH" =~ /snap/bin ]] ) || PATH="/usr/local/bin:/snap/bin:$PATH"

# Sends output to console as well as the $BUILDLOG file
debug() { [ -z "$DEBUG" ] || echo -e "$@" | tee -a "$BUILDLOG"; } 

skip_op() {	debug 'Skipping: ' "$@"; }

(egrep -qi 'ubuntu' /etc/issue || egrep -qi 'raspbian|ubuntu|debian' /etc/os-release) 2> /dev/null \
	|| debug "We're built for Debian/Ubuntu, mainly for the Pi (will try anyway, but YMMV)"

# Display information on last run
LASTRUNCOMMAND=$(ls "$INSTALLDIR"/logs/build-command-line-*log 2> /dev/null | egrep '# \(completed\)' | tail -1 | xargs cat)
if [ ".$PRINT_LAST_CMDLINE" != '.' ]; then
	[ -z "$LASTRUNCOMMAND" ] && LASTRUNCOMMAND=$(ls "$INSTALLDIR"/logs/build-command-line-*log 2> /dev/null | tail -1 | xargs cat)
	echo "${LASTRUNCOMMAND:-# no history}"
	exit 0
else
	if [ ".$LASTRUNCOMMAND" != '.' ]; then
		debug "Last completed run:\n  ${LASTRUNCOMMAND:-# no history}" 
		debug "For full command history: 'less $INSTALLDIR/logs/build-command-line*log'"
	fi
fi

[ -z "${NODE_CONFIG_FILE}" ] && NODE_CONFIG_FILE="$CARDANO_FILEDIR/${BLOCKCHAINNETWORK}-config.json"
[ "${SUDO}" = 'Y' ] && sudo="sudo" || sudo=""
if [ "${SUDO}" = 'Y' ] && [ $(id -u) -eq 0 ]; then
	debug "Running script as root (not needed; use 'sudo')"
fi

debug "To get the latest version: 'git clone https://github.com/rgoerwit/pi-cardano-node-setup/' (refresh: 'git pull')"
debug "Please DOUBLE CHECK THE FOLLOWING DATA:"
debug "    INSTALLDIR is '/home/${INSTALL_USER}'"
debug "    BUILDDIR is '/home/${BUILD_USER}/Cardano-BuildDir'"
debug "    CARDANO_FILEDIR is '${INSTALLDIR}/files'"
debug "    NODE_CONFIG_FILE is '${NODE_CONFIG_FILE}'"
debug "    External hostname, ${EXTERNAL_HOSTNAME}: IPv4 = ${EXTERNAL_IPV4_ADDRESS:-unknown}; IPv6 = ${EXTERNAL_IPV6_ADDRESS:-unknown}"
sleep 5
[ "$LISTENPORT" -lt 6000 ] && [ ".$POOLNAME" != '.' ]	&& debug "    Note: Use ports >= 6000 for block producers (helps keep stuff straight)"
[ "$LISTENPORT" -ge 6000 ] && [ ".$POOLNAME" = '.' ]	&& debug "    Note: Use ports < 6000 for relays, >= 6000 for BPs (helps keep stuff straight)"

# -h argument supplied - parse WiFi info (WiFi usually not recommended, but OK esp. for relay, in a pinch)
if [ ".${HIDDEN_WIFI_INFO}" != '.' ]; then
	HIDDENWIFI=$(echo "$HIDDEN_WIFI_INFO" | awk -F: '{ print $1 }')
	HIDDENWIFIPASSWORD=$(echo "$HIDDEN_WIFI_INFO" | awk -F: '{ print $2 }')
	[ -z "${HIDDENWIFI}" ] && [ -z "${HIDDENWIFIPASSWORD}" ] \
		&& err_exit 45 "$0: Please supply a WPA WiFi NetworkID:Password (or omit the -h argument for no WiFi)"
fi

[ -z "${IOHKREPO}" ]			&& IOHKREPO="https://github.com/input-output-hk"
[ -z "${IOHKAPIREPO}" ]			&& IOHKAPIREPO="https://api.github.com/repos/input-output-hk"
[ -z "${GUILDREPO}" ]			&& GUILDREPO="https://github.com/cardano-community/guild-operators"
[ -z "${GUILDREPO_RAW}" ]		&& GUILDREPO_RAW="https://raw.githubusercontent.com/cardano-community/guild-operators"
[ -z "${GUILDREPOBRANCH}" ]		&& GUILDREPOBRANCH='master'
[ -z "${GUILDREPO_RAW_URL}" ]	&& GUILDREPO_RAW_URL="${GUILDREPO_RAW}/${GUILDREPOBRANCH}"
[ -z "${SPOSREPO}" ]			&& SPOSREPO='https://github.com/gitmachtl/scripts'
[ -z "${WPA_SUPPLICANT}" ]		&& WPA_SUPPLICANT="/etc/wpa_supplicant/wpa_supplicant.conf"
[ -z "$CARDANOBRANCH" ]			&& CARDANOBRANCH='master'
WGET="wget --quiet --retry-connrefused --waitretry=10 --read-timeout=20 --timeout $WGET_TIMEOUT -t 5"
[ -z "$GHCVERSION" ] && GHCVERSION="8.10.4"
GHCARCHITECTURE="$(arch)"         # could potentially be aarch64, arm7, arm8, etc. for example; see http://downloads.haskell.org/~ghc/
GCCMARMARG=""                     # will be -marm for Raspberry Pi OS 32 bit; blank for Ubuntu 64
if [ -z "$GHC_GCC_ARCH" ]; then
	(echo "$(arch)" | egrep -q 'arm|aarch') \
		&& GHC_GCC_ARCH="-march=Armv8-A"  # will be -march=armv7-a for Raspberry Pi OS 32 bit; -march=Armv8-A for Ubuntu 64
fi
[ -z "$GHCOS" ] && GHCOS="deb10"  # could potentially be deb9, etc, for example; see http://downloads.haskell.org/~ghc/
CABAL="$INSTALLDIR/cabal"
MAKE='make'
PIVERSION=$(cat /proc/cpuinfo | egrep '^Model' | sed 's/^Model\s*:\s*//i')
PIP="pip$(apt-cache pkgnames | egrep '^python[2-9]*$' | sort | tail -1 | tail -c 2 |  tr -d '[:space:]' 2> /dev/null)"; 

# Guess which cabal binaries to use
#
[ -z "$CABAL_VERSION" ] && CABAL_VERSION='3.5.0.0'
[ -z "$CABALDOWNLOADPREFIX" ] && CABALDOWNLOADPREFIX="https://downloads.haskell.org/~cabal/cabal-install-${CABAL_VERSION}/cabal-install-${CABAL_VERSION}"
if echo "$(arch)" | egrep -q 'arm|aarch'; then
	[ -z "$CABALDOWNLOADPREFIX" ] && CABALDOWNLOADPREFIX="http://home.smart-cactus.org/~ben/ghc/cabal-install-${CABAL_VERSION}"
fi
[ -z "$CABALARCHITECTURE" ] && CABALARCHITECTURE="$(arch)" # On a Pi ubuntu 64 is aarch64 See http://home.smart-cactus.org/~ben/ghc/
[ -z "$CABAL_OS" ] && CABAL_OS=$(lsb_release -a 2> /dev/null | egrep '^(Distributor|Release)' | awk '{ print $(NF) }' | xargs | tr ' ' '-' | tr '[[:upper:]]' '[[:lower:]]')
if $WGET --method HEAD "${CABALDOWNLOADPREFIX}-${CABALARCHITECTURE}-${CABAL_OS}.tar.xz" 2>> "$BUILDLOG"; then
	: yay nothing more needed
else
	if echo "$CABAL_OS" | egrep -qi 'ubuntu'; then 
		DVERSION=$(expr `echo "$CABAL_OS" | cut -f 2 -d'-' | cut -f 1 -d'.'` / 2); # Debian version often = floor(Ubuntu version / 2)
		CABAL_OS="debian-$DVERSION"; 
	fi
	if $WGET --method HEAD "${CABALDOWNLOADPREFIX}-${CABALARCHITECTURE}-${CABAL_OS}.tar.xz" 2>> "$BUILDLOG"; then
		: yay nothing more needed
	else
		CABAL_OS='unknown-linux'
	fi
fi
# debug "Guessing cabal tarball: ${CABALDOWNLOADPREFIX}-${CABALARCHITECTURE}-${CABAL_OS}.tar.xz"

# In case our own compilations fail, use GHCUP to build ghc and cabal later
#
GHCUP_INSTALL_PATH=''
#
do_ghcup_install () {

	BOOTSTRAP_HASKELL_GHC_VERSION="$GHCVERSION"
	BOOTSTRAP_HASKELL_CABAL_VERSION="$CABAL_VERSION"
	export BOOTSTRAP_HASKELL_NONINTERACTIVE='Y'
	GHCUP_INSTALL_PATH="$HOME/.ghcup/bin"
	debug "Falling back to GHCUP install, in $GHCUP_INSTALL_PATH"
	pushd "$HOME"								1>> "$BUILDLOG" 2>&1
	curl --proto '=https' --tlsv1.2 -sSf 'https://get-ghcup.haskell.org' | sh 1>> "$BUILDLOG" 2>&1 \
		|| err_exit 151 "Failed to build using GHCUP; aborting"
	PATH="$GHCUP_INSTALL_PATH:$PATH"; export PATH
	ghcup upgrade 1>> "$BUILDLOG" 2>&1
	if [[ ! -z "$GHCVERSION" ]]; then
		ghcup install ghc "$GHCVERSION" 		1>> "$BUILDLOG" 2>&1
		ghcup set ghc "$GHCVERSION"				1>> "$BUILDLOG" 2>&1
	fi
	if [[ ! -z "$CABAL_VERSION" ]]; then
		ghcup install cabal "$CABAL_VERSION"	1>> "$BUILDLOG" 2>&1
		ghcup set cabal "$CABAL_VERSION"		1>> "$BUILDLOG" 2>&1
	fi
	( [ -x "$CABAL" ] && [ "$CABAL_VERSION" = $($CABAL --version | head -1 | awk '{ print $(NF) }' 2> /dev/null) ] ) \
		|| 'cp' -f "$GHCUP_INSTALL_PATH/cabal" "$CABAL"
	CABAL="$GHCUP_INSTALL_PATH/cabal"
	popd 1>> "$BUILDLOG" 2>&1

}

git_latest_release() { 
	curl --silent -L -H 'Accept: application/json' "${1}/releases/latest" | jq '.tag_name' | tr -d '"' 
}

# Generalized code for refreshing a GitHub repository, if needed
#
download_github_code () {

	MYBUILDDIR=$1
	MYINSTALLDIR=$2
	MYREPOSITORYURL=$3
	MYSKIPRECOMPILEFLAG=$4
	MYBUILDLOG=$5
	MYPROGINSTALLDIR=$6
	MYREQUIREDVERSION=$7
	MYINSTALLPROGNAME=$8
	VERSIONMUSTMATCH=$9

	if [ -z "$MYREQUIREDVERSION" ]; then
		MYREQUIREDVERSION=$(git_latest_release "$MYREPOSITORYURL")
		MYREQUIREDVERSION=$(echo "$MYREQUIREDVERSION" | sed 's/^[^0-9]*\([0-9][0-9]*\.[0-9][0-9.]*\).*$/\1/' | egrep '.' | head -1)
		debug "No minimum version specified for $(echo "$MYREPOSITORYURL" | sed 's:/*$::' | awk -F/ '{ print $(NF) }'); latest version on GitHub is ${MYREQUIREDVERSION:-unknown}"
		[ -z "$MYREQUIREDVERSION" ] && MYREQUIREDVERSION='0.0'
	fi

	# Try to determine installed version of $MYINSTALLPROGNAME (usually the same as $MYGITPROGNAME)
	ISLIBRARY='N'
	MYVERSION=''
	MYGITPROGNAME=$(echo "$MYREPOSITORYURL" | sed 's|/*$||' | awk -F/ '{ print $(NF) }')
	[ -z "$MYINSTALLPROGNAME" ] && MYINSTALLPROGNAME="$MYGITPROGNAME"
	debug "Checking current version of ${MYPROGINSTALLDIR:-$MYINSTALLDIR}/$MYINSTALLPROGNAME (if present)"
	if [ -x "${MYPROGINSTALLDIR:-$MYINSTALLDIR}/$MYINSTALLPROGNAME" ] && [ -f "${MYPROGINSTALLDIR:-$MYINSTALLDIR}/$MYINSTALLPROGNAME" ]; then
		# Most executables will cough up some sort of version number when passed '--version' or 'version' to stdout or stderr
		MYVERSION=$(${MYPROGINSTALLDIR:-$MYINSTALLDIR}/$MYINSTALLPROGNAME --version 2> /dev/null | sed 's/^[^0-9]*\([0-9][0-9]*\.[0-9][0-9.]*\).*$/\1/' | egrep '.' | head -1)
		[ -z "$MYVERSION" ] && MYVERSION=$(${MYPROGINSTALLDIR:-$MYINSTALLDIR}/$MYINSTALLPROGNAME --version 2>&1 | egrep -vi 'error|invalid' | sed 's/^[^0-9]*\([0-9][0-9]*\.[0-9][0-9.]*\).*$/\1/' | egrep '.' | head -1)
		[ -z "$MYVERSION" ] && MYVERSION=$(${MYPROGINSTALLDIR:-$MYINSTALLDIR}/$MYINSTALLPROGNAME version 2>&1 | egrep -vi 'error|invalid' | sed 's/^[^0-9]*\([0-9][0-9]*\.[0-9][0-9.]*\).*$/\1/' | egrep '.' | head -1)
		[[ "$MYVERSION" =~ [Uu]sage ]] && MYVERSION=''  # Give up if we got a usage message
	else
		if (stat "${MYPROGINSTALLDIR:-$MYINSTALLDIR}/$MYINSTALLPROGNAME".{so,la} -c '%n' 2> /dev/null | egrep -q '/lib') && (ldconfig -pNv | egrep -q "$MYGITPROGNAME"); then
			ISLIBRARY='Y'
		fi
	fi
	# [ -z "$MYVERSION" ] && debug "Can't determine version for: ${MYPROGINSTALLDIR:-$MYINSTALLDIR}/$MYGITPROGNAME"
	debug "Checking whether GitHub code refresh is needed for $MYINSTALLPROGNAME (version, ${MYVERSION:-unknown}; required version, ${MYREQUIREDVERSION})"

	pushd "$MYBUILDDIR"	1>> "$MYBUILDLOG" 2>&1
	[ ".$MYSKIPRECOMPILEFLAG" = '.Y'  ]	|| 'rm' -rf "$MYBUILDDIR/$MYGITPROGNAME"	1>> "$MYBUILDLOG" 2>&1
	[ -f "$MYBUILDDIR/$MYGITPROGNAME" ]	&& 'rm' -f  "$MYBUILDDIR/$MYGITPROGNAME"	1>> "$MYBUILDLOG" 2>&1  # If file exists with dirname, delete
	[ -d "$MYBUILDDIR/$MYGITPROGNAME" ]	|| {
		debug "Cloning source: git clone --recurse-submodules $MYREPOSITORYURL"
		git clone --recurse-submodules "$MYREPOSITORYURL" 1>> "$MYBUILDLOG" 2>&1
	}
	MY_COMPARE_OP='ge'
	[ ".$VERSIONMUSTMATCH" = '.Y' ] && MY_COMPARE_OP='eq'
	if [ ".$MYSKIPRECOMPILEFLAG" = '.Y' ] \
		&& ( [ ".$ISLIBRARY" = '.Y' ] || [ -e "${MYPROGINSTALLDIR:-$MYINSTALLDIR}/$MYINSTALLPROGNAME" ] ) \
		&& dpkg --compare-versions "${MYVERSION:-000.000}" "${MY_COMPARE_OP}" "${MYREQUIREDVERSION}"
	then
		debug "Refresh not needed for $MYINSTALLPROGNAME ($MYREPOSITORYURL)"
		popd 1>> "$MYBUILDLOG" 2>&1
		return 1
	else
		[ ".$MYSKIPRECOMPILEFLAG" != '.Y' ] && debug "No -x argument; forcing recompile, regardless of version"
		debug "Refreshing GitHub code for $MYINSTALLPROGNAME from: $MYREPOSITORYURL"
		cd "./$MYGITPROGNAME"
		git fetch --all --recurse-submodules --tags 1>> "$BUILDLOG" 2>&1
		MYTAG=$(git tag | sort -V | egrep '[0-9]' | egrep "^([a-z-]*-)?v?$MYREQUIREDVERSION$" | head -1)
		if [[ ! -z "$MYTAG" ]]; then
			debug "Trying to download version $MYREQUIREDVERSION as GitHub tag, tags/$MYTAG"
				git checkout "tags/$MYTAG"	1>> "$MYBUILDLOG" 2>&1 \
				&& git fetch				1>> "$MYBUILDLOG" 2>&1
		else
			if git checkout "$MYREQUIREDVERSION"	1>> "$MYBUILDLOG" 2>&1 \
				&& git fetch						1>> "$MYBUILDLOG" 2>&1
			then
				debug "Ended up checking out $MYREQUIREDVERSION (no tag)"
			else
				debug "Can't checkout $MYREQUIREDVERSION (as tag, tags/$MYTAG, or version, $MYREQUIREDVERSION); doing hard reset and pulling"
				git reset --hard	1>> "$MYBUILDLOG" 2>&1
				git pull			1>> "$MYBUILDLOG" 2>&1
			fi
		fi
		popd 1>> "$MYBUILDLOG" 2>&1
		return 0
	fi
}

create_and_secure_installdir () {

	MY_BLOCKCHAINNETWORK=$1
	MY_INSTALLDIR=$2
	MY_CARDANO_FILEDIR=$3
	MY_CARDANO_DBDIR=$4
	MY_CARDANO_PRIVDIR=$5
	MY_CARDANO_SCRIPTDIR=$6
	MY_CARDANO_SPOSDIR=$7
	MY_INSTALLUSER=$8
	TOPOLOGYFILEOWNER=$9

	debug "(Re)checking/building cardano-node directory structure in $MY_INSTALLDIR"
	cd "$MY_INSTALLDIR"
	for INSTALL_SUBDIR in "$MY_CARDANO_FILEDIR" "$MY_CARDANO_DBDIR" "$MY_CARDANO_PRIVDIR" "$MY_CARDANO_SCRIPTDIR" "$MY_CARDANO_SPOSDIR" 'cold-keys' 'guild-db' 'logs' 'sockets' 'pkgconfig'; do
		(echo "$INSTALL_SUBDIR" | egrep -q '^/') || INSTALL_SUBDIR="${MYINSTALLDIR}/${INSTALL_SUBDIR}" 
		mkdir -p "$INSTALL_SUBDIR"						2>/dev/null
		chown -R root.$MY_INSTALLUSER "$INSTALL_SUBDIR"	2>/dev/null
		if [ "$INSTALL_SUBDIR" = "$MY_CARDANO_DBDIR" ] || [[ "$INSTALL_SUBDIR" =~ guild-db$ ]] || [[ "$INSTALL_SUBDIR" =~ logs$ ]] || [[ "$INSTALL_SUBDIR" =~ sockets$ ]]; then
			find "$INSTALL_SUBDIR" -type d -exec chmod 2775 {} \; # Cardano group must write to here
			find "$INSTALL_SUBDIR" -type f -exec chmod 0664 {} \; # Cardano group must write to here
		else
			if [ "$INSTALL_SUBDIR" = "$MY_CARDANO_FILEDIR" ]; then
				find "$INSTALL_SUBDIR" -type d -exec chmod 1775 {} \; # Cardano group DOES need to write to here but can't delete other users' files
				find "$INSTALL_SUBDIR" -type f -exec chmod 0644 {} \;
				# Ensuring cardano user itself can modify its topology file (topologyUpdater.sh wants this)
				chown ${TOPOLOGYFILEOWNER:-$MY_INSTALLUSER}.${TOPOLOGYFILEOWNER:-$MY_INSTALLUSER} "${INSTALL_SUBDIR}/${MY_BLOCKCHAINNETWORK}-topology.json"
				chmod ug+w "${INSTALL_SUBDIR}/${MY_BLOCKCHAINNETWORK}-topology.json"
			else
				if [ "$INSTALL_SUBDIR" = "$MY_CARDANO_SCRIPTDIR" ]; then
					find "$INSTALL_SUBDIR" -type d -exec chmod 1775 {} \; # Cardano group DOES need to write to here but can't delete other users' files
					find "$INSTALL_SUBDIR" -type f -exec chmod 0644 {} \; -name '*.sh' -exec chmod a+x {} \;
					# Guild scripts want to update their topologyUpdater.sh files
					chown ${TOPOLOGYFILEOWNER:-$MY_INSTALLUSER}.${TOPOLOGYFILEOWNER:-$MY_INSTALLUSER} "${MY_CARDANO_SCRIPTDIR}/topologyUpdater.sh" 
					chmod 0775 "${MY_CARDANO_SCRIPTDIR}/topologyUpdater.sh"
				else
					if [ "$INSTALL_SUBDIR" = "$MY_CARDANO_SPOSDIR" ]; then
						find "$INSTALL_SUBDIR" -type d -exec chmod =0700 {} \; # Cardano group does not need to write to here
						find "$INSTALL_SUBDIR" -type f -exec chmod =0600 {} \; -name '*.sh' -exec chmod u+x {} \;
					else
						if [ "$INSTALL_SUBDIR" = "$MY_CARDANO_PRIVDIR" ]; then
							debug "Placing secure permissions (go-rwx) on files in $INSTALL_SUBDIR"
							chmod 2750 "$INSTALL_SUBDIR"											# Cardano group does NOT need to write to here
							find "$INSTALL_SUBDIR" -maxdepth 1 -type f -exec chmod 0640 {} \;		# But others should not see material in this area
							chown "$MY_INSTALLUSER" "$INSTALL_SUBDIR"/*.{skey,cert} 2> /dev/null	# candano-node insists on this
							chmod 0400 "$INSTALL_SUBDIR"/*.{skey,cert} 2> /dev/null
							find "$INSTALL_SUBDIR" -mindepth 1 -type d -exec chmod =0700 {} \;		# And not even the cardano group should see below depth 1
							find "$INSTALL_SUBDIR" -mindepth 2 -type f -exec chmod =0600 {} \;
						else
							find "$INSTALL_SUBDIR" -type d -exec chmod 2755 {} \; # Cardano group does NOT need to write to here 
							find "$INSTALL_SUBDIR" -type f -exec chmod 0644 {} \; -name '*.sh' -exec chmod a+x {} \;
						fi
					fi
				fi
			fi
		fi
	done
}

cabal_install_software () {

	MYCABALBUILDDIR=$1
	MYCABALINSTALLDIR=$2
	MYCABALPACKAGENAME=$3
	MYCABAL=$4
	MYCABALBUILDLOG=$5
	MYCABALPRODUCT=$6
	MYGHCVERSION=$7
	MYLOOKFORTHISSTRINGINPATH=$8

	[ -z "$MYCABALPRODUCT" ] && MYCABALPRODUCT="$MYCABALPACKAGENAME"
	pushd "$MYCABALBUILDDIR/$MYCABALPACKAGENAME" 1>> "$MYCABALBUILDLOG" 2>&1 \
		|| err_abort 41 "$0: Can't 'cd $MYCABALBUILDDIR/$MYCABALPACKAGENAME'; aborting"
	debug "Downloaded $MYCABALPRODUCT; installing to $MYCABALINSTALLDIR"
	# $MYCABAL update	1>> "$MYCABALBUILDLOG" 2>&1
	$MYCABAL clean	1>> "$MYCABALBUILDLOG" 2>&1
	$MYCABAL update 1>> "$MYCABALBUILDLOG" 2>&1
	if [[ ! -z "$MYGHCVERSION" ]]; then
		debug "GHC version supplied; doing a config: $MYCABAL configure -O0 -w ghc-${MYGHCVERSION}"
		$MYCABAL configure -O0 -w "ghc-${MYGHCVERSION}"	1>> "$MYCABALBUILDLOG" 2>&1
	else
		$MYCABAL configure	1>> "$MYCABALBUILDLOG" 2>&1
	fi
	if $MYCABAL build all 1>> "$MYCABALBUILDLOG" 2>&1; then
		# If we recompiled or user wants new version, remove symlinks if they exist in prep for copying in new binaries
		mv -f "$MYCABALINSTALLDIR/$MYCABALPRODUCT" "$MYCABALINSTALLDIR/$MYCABALPRODUCT.OLD"	1>> "$MYCABALBUILDLOG" 2>&1
		cp -f $(find "$MYCABALBUILDDIR/$MYCABALPACKAGENAME" -type f -name "$MYCABALPRODUCT" ! -path '*OLD*' | egrep "${MYLOOKFORTHISSTRINGINPATH:-.}" | tail -1) "$MYCABALINSTALLDIR/$MYCABALPRODUCT" 1>> "$MYCABALBUILDLOG" 2>&1 \
			|| { 
				mv -f "$MYCABALINSTALLDIR/$MYCABALPRODUCT.OLD" "$MYCABALINSTALLDIR/$MYCABALPRODUCT" 1>> "$MYCABALBUILDLOG" 2>&1
				err_exit 81 "Failed to build $MYCABALPRODUCT; aborting"
			}
	else
		err_exit 43 "$0: Failed to build $MYCABALPRODUCT; aborting"
	fi
	popd 1>> "$MYCABALBUILDLOG"  2>&1

}

# Make sure our build user exists
#
debug "Checking and (if need be) making build user: ${BUILD_USER}"
if id "$BUILD_USER" 1>> /dev/null 2>&1; then
	: do nothing
else
    # But...if we have to create the build user, lock the password
    useradd -m -U -s /bin/bash -d "/home/$BUILD_USER" "$BUILD_USER"		1>> "$BUILDLOG" 2>&1
	usermod -a -G users "$BUILD_USER" -s /usr/sbin/nologin				1>> "$BUILDLOG" 2>&1
    passwd -l "$BUILD_USER"												1>> "$BUILDLOG"
fi
(stat "/home/${BUILD_USER}" --format '%A' | egrep -q '\---$') \
	|| (chown $BUILD_USER.$BUILD_USER "/home/${BUILD_USER}"; chmod o-rwx "/home/${BUILD_USER}")
#
mkdir "$BUILDDIR" 2> /dev/null
chown "${BUILD_USER}.${BUILD_USER}" "$BUILDDIR"
chmod 2755 "$BUILDDIR"

[ ".$SKIP_RECOMPILE" = '.Y' ] || debug "You are compiling (NO -x flag supplied); this may take a long time...."
debug "To monitor progress, run: 'tail -f \"$BUILDLOG\"'"

# Update system, install prerequisites, utilities, etc.
#
debug "Updating system; ensuring necessary prerequisites are installed"
if ischroot; then
	debug "Putting kernel-related updates on hold (we're in a chroot)"
	apt-mark hold initramfs-tools linux-image-generic linux-headers-generic cryptsetup-initramfs flash-kernel flash-kernel:arm64 1>> "$BUILDLOG" 2>&1
else
	apt-mark unhold initramfs-tools linux-image-generic linux-headers-generic cryptsetup-initramfs flash-kernel flash-kernel:arm64 1>> "$BUILDLOG" 2>&1
fi
$APTINSTALLER clean			1>> "$BUILDLOG" 2>&1
$APTINSTALLER autoremove	1>> "$BUILDLOG" 2>&1
$APTINSTALLER update		1>> "$BUILDLOG" 2>&1
$APTINSTALLER update --fix-missing	1>> "$BUILDLOG" 2>&1
$APTINSTALLER upgrade       1>> "$BUILDLOG" 2>&1
$APTINSTALLER dist-upgrade  1>> "$BUILDLOG" 2>&1
modinfo ip_tables			1>> "$BUILDLOG" 2>&1 \
	|| ischroot \
		|| $APTINSTALLER install --reinstall "linux-modules-$(ls -t /lib/modules | tail -1 | awk -F/ '{ print $(NF) }')" 1>> "$BUILDLOG" 2>&1
# Install a bunch of necessary development and support packages
$APTINSTALLER install \
	apache2-utils aptitude autoconf automake bc bsdmainutils build-essential curl dialog dos2unix emacs \
	fail2ban g++ git gnupg gparted htop ifupdown inetutils-traceroute iproute2 jq libbz2-dev libffi-dev \
	libffi7 libgmp-dev libgmp10 libio-socket-ssl-perl liblz4-dev libncursesw5 libnuma-dev libpam-google-authenticator \
	libpq-dev libqrencode4 librocksdb-dev libsnappy-dev libsodium-dev libssl-dev libsystemd-dev libtinfo-dev \
	libtinfo5 libtool libudev-dev libusb-1.0-0-dev make moreutils net-tools netmask nginx-full openssl \
	pkg-config python-is-python3 python2 python3 python3-pip rng-tools rocksdb-tools rsync secure-delete snapd \
	sqlite sqlite3 ssl-cert systemd tcptraceroute tmux unzip wcstools xxd zlib1g-dev \
		1>> "$BUILDLOG" 2>&1 \
			|| err_exit 71 "$0: Failed to install apt-get dependencies; aborting"
# Enable unattended, automatic updates
$APTINSTALLER install unattended-upgrades					1>> "$BUILDLOG" 2>&1
$APTINSTALLER dpkg-reconfigure -plow unattended-upgrades	1>> "$BUILDLOG" 2>&1
# Now start in on less common or harder-to-install stuff we'll need
$APTINSTALLER install cython3		1>> "$BUILDLOG" 2>&1 \
	|| $APTINSTALLER install cython	1>> "$BUILDLOG" 2>&1 \
		|| debug "$0: Cython could not be installed with '$APTINSTALLER install'; will try to build anyway"
($APTINSTALLER install nmap || ischroot || snap install nmap) 1>> "$BUILDLOG" 2>&1
if ! ischroot; then
	snap install nmap 					1>> "$BUILDLOG" 2>&1 || snap refresh nmap	1>> "$BUILDLOG" 2>&1
	snap connect nmap:network-control	1>> "$BUILDLOG" 2>&1
	snap install rustup --classic		1>> "$BUILDLOG" 2>&1 || snap refresh rustup	1>> "$BUILDLOG" 2>&1
	snap install jcli --classic			1>> "$BUILDLOG" 2>&1 || snap refresh jcli	1>> "$BUILDLOG" 2>&1
	snap install go --classic			1>> "$BUILDLOG" 2>&1 || snap refresh go		1>> "$BUILDLOG" 2>&1
else
	## Truly dangerous just to run someone else's shell script blind, off the internet
	#curl --proto '=https' --tlsv1.2 -sSf 'https://sh.rustup.rs' | sh 1>> "$BUILDLOG" 2>&1
	debug "Note: You'll need to rerun this script after booting your chroot as your primary boot device"
fi
debug "Registering deb.nodesource.com repository, if needed"
egrep -qr --include '*.list' 'deb.nodesource.com' '/etc/apt/sources.list' '/etc/apt/sources.list.d/' \
	|| (curl -sL 'https://deb.nodesource.com/setup_current.x' | bash - 1>> "$BUILDLOG" 2>&1)
debug "Registering dl.yarnpkg.com repository, if needed"
egrep -qr --include '*.list' 'dl.yarnpkg.com' '/etc/apt/sources.list' '/etc/apt/sources.list.d/' \
	|| (curl -sS 'https://dl.yarnpkg.com/debian/pubkey.gpg' | apt-key add - 1>> "$BUILDLOG" 2>&1)
debug "Adding yarnpkg stable main repository: /etc/apt/sources.list.d/yarn.list"
# echo 'deb [signed-by=/usr/share/keyrings/yarnkey.gpg] https://dl.yarnpkg.com/debian stable main' 1> '/etc/apt/sources.list.d/yarn.list' 2>> "$BUILDLOG"
echo 'deb https://dl.yarnpkg.com/debian stable main' 1> '/etc/apt/sources.list.d/yarn.list' 2>> "$BUILDLOG"
$APTINSTALLER update			1>> "$BUILDLOG" 2>&1
debug "Installing/refreshing nodejs and yarn"
$APTINSTALLER install nodejs	1>> "$BUILDLOG" 2>&1
$APTINSTALLER install yarn		1>> "$BUILDLOG" 2>&1 \
	|| err_exit 101 "$0: Faild to install yarn (and possibly nodejs); aborting; see $BUILDLOG"
npm install cardanocli-js		1>> "$BUILDLOG" 2>&1
# OK, now clean up anything lying around that shouldn't be there...again
$APTINSTALLER clean			1>> "$BUILDLOG" 2>&1
$APTINSTALLER autoremove	1>> "$BUILDLOG" 2>&1
$APTINSTALLER autoclean		1>> "$BUILDLOG" 2>&1

if [ ".$SKIP_RECOMPILE" != '.Y' ]; then
	$APTINSTALLER install --reinstall build-essential 1>> "$BUILDLOG" 2>&1
	$APTINSTALLER install --reinstall gcc             1>> "$BUILDLOG" 2>&1
	dpkg-reconfigure build-essential                  1>> "$BUILDLOG" 2>&1
	dpkg-reconfigure gcc                              1>> "$BUILDLOG" 2>&1
fi
$APTINSTALLER install llvm-9                      1>> "$BUILDLOG" 2>&1 || err_exit 71 "$0: Failed to install llvm-9; aborting"
$APTINSTALLER install rpi-imager                  1>> "$BUILDLOG" 2>&1 \
	|| snap install rpi-imager 					  1>> "$BUILDLOG" 2>&1  # If not present, no biggie
$APTINSTALLER install rpi-eeprom                  1>> "$BUILDLOG" 2>&1  # Might not be present, and if so, no biggie

EEPROM_UPDATE="$(which rpi-eeprom-update 2> /dev/null)"
if [ ".$EEPROM_UPDATE" != '.' ] && [ -x "$EEPROM_UPDATE" ]; then 
	if $EEPROM_UPDATE 2> /dev/null | egrep -q 'BOOTLOADER: *up-to-date'; then
		: Eeprom up to date
	else
		if egrep -q 'FIRMWARE_RELEASE_STATUS="stable"' '/etc/default/rpi-eeprom-update' 1>> "$BUILDLOG" 2>&1; then
			debug "Firmware appears already to be updated (using latest stable version)"
		else
			debug "Updating eeprom: $EEPROM_UPDATE -a"
			debug 'If you want to USB boot, see: https://blog.emtwo.ch/2020/07/boot-raspberry-pi-4-from-usb-ssd.html'
			sed -i "/etc/default/rpi-eeprom-update" -e "s|^\#* *FIRMWARE_RELEASE_STATUS=['\"][^'\"]*['\"]|FIRMWARE_RELEASE_STATUS=\"stable\"|g" 1>> "$BUILDLOG" 2>&1 \
				|| debug 'Unable to set FIRMWARE_RELEASE_STATUS="stable" in /etc/default/rpi-eeprom-update; skipping'
			$EEPROM_UPDATE -a 1>> "$BUILDLOG" 2>&1  # Don't use -d; will wipe out current config
		fi
    fi
fi

$APTINSTALLER install net-tools openssh-server	1>> "$BUILDLOG" 2>&1
systemctl daemon-reload							1>> "$BUILDLOG" 2>&1
systemctl enable ssh							1>> "$BUILDLOG" 2>&1
if [ ".$START_SERVICES" != '.N' ]; then
	debug "(Re)starting SSH, ensuring NTP service is running ('timedatectl set-ntp true')"
	systemctl start ssh								1>> "$BUILDLOG" 2>&1;	sleep 3
	systemctl is-active ssh 						1> /dev/null \
		|| err_exit 136 "$0: Problem enabling (or starting) ssh service; aborting (run 'systemctl status ssh')"
	timedatectl set-ntp true						1>> "$BUILDLOG" 2>&1 \
		|| debug "Can't enable NTP; install chrony or ntpd or check timedatectl:  'timedatectl timesync-status'"

fi

if [ ".$OVERCLOCK_SPEED" != '.' ]; then
    debug "Checking and (if need be setting up) overclocking (speed=$OVERCLOCK_SPEED, PIVERSION=$PIVERSION)"
	# Find config.txt file
	BOOTCONFIG="/boot/config.txt"
	if [ -f "$BOOTCONFIG" ]; then
		: do nothing
	else if [ -f "/boot/firmware/config.txt" ]; then
			export BOOTCONFIG="/boot/firmware/config.txt"
		fi
	fi

	# Set up modest overclock on a Pi 4
	#
	if echo "$PIVERSION" | egrep -qi 'Pi 4'; then
		if egrep -q '^[	 ]*arm_freq=' "$BOOTCONFIG"; then
			debug "Overclocking already set up; skipping (edit $BOOTCONFIG file to change settings)"
		else
		    [[ "$OVERCLOCK_SPEED" = [0-9]* ]] || err_exit 19 "$0: For argument -o <speed>, <speed> must be an integer (e.g., 2100); aborting"
			debug "Current CPU temp: `vcgencmd measure_temp`"
			debug "Current Max CPU speed: `cat /sys/devices/system/cpu/cpu0/cpufreq/cpuinfo_max_freq`"
			debug "Setting speed to $OVERCLOCK_SPEED; please check $BOOTCONFIG file before next restart"
			cat <<- _EOF >> "$BOOTCONFIG"

				over_voltage=5
				arm_freq=$OVERCLOCK_SPEED
				# gpu_freq=700
				# gpu_mem=256
				# sdram_freq=3200

			_EOF
		fi
	fi
fi

# Set up restrictive firewall - just SSH and RDP, plus an external Prometheus
#
if [ ".$SKIP_FIREWALL_CONFIG" = '.Y' ] || [ ".$DONT_OVERWRITE" = '.Y' ]; then
    debug "Skipping firewall configuration at user request"
	[ ".$HOSTED_GRAFANA" = '.Y' ] \
		&& debug "Note: Grafana traffic may require network ACL or policy changes"
else
	debug "Prometheus is unauthenticated; ensuring it's stopped while configuring firewall"
	systemctl stop prometheus 	1>> "$BUILDLOG" 2>&1
    debug "Configuring firewall for prometheus, SSH; subnets:\n    $MY_SUBNETS"
	ufw --force reset			1>> "$BUILDLOG" 2>&1
	if apt-cache pkgnames 2> /dev/null | egrep -q '^ufw$'; then
		ufw disable 1>> "$BUILDLOG" # install ufw if not present
	else
		$APTINSTALLER install ufw 1>> "$BUILDLOG" 2>&1
	fi
	# echo "Installing firewall with only ports 22, 3000, 3001, and 3389 open..."
	ufw default deny incoming    1>> "$BUILDLOG" 2>&1
	ufw default allow outgoing   1>> "$BUILDLOG" 2>&1
	debug "Using $PREPROXY_PROMETHEUS_PORT as pre-proxy prometheus port (proxy port = $EXTERNAL_PROMETHEUS_PORT)"
	for netw in $(echo "$MY_SUBNETS" | sed 's/ *, */ /g'); do
	    [ -z "$netw" ] && next
		NETW=$(netmask --cidr "$netw" | tr -d ' \n\r' 2>> "$BUILDLOG")
		ufw allow proto tcp from "$NETW" to any port ssh 1>> "$BUILDLOG" 2>&1
		ufw allow proto tcp from "$NETW" to any port "$PREPROXY_PROMETHEUS_PORT"	1>> "$BUILDLOG" 2>&1
		ufw allow proto tcp from "$NETW" to any port "$CARDANO_PROMETHEUS_PORT"		1>> "$BUILDLOG" 2>&1
		ufw allow proto tcp from "$NETW" to any port "$EXTERNAL_PROMETHEUS_PORT"	1>> "$BUILDLOG" 2>&1
		if [ ".$SETUP_DBSYNC" = '.Y' ]; then
			ufw allow proto tcp from "$NETW" to any port 5432 1>> "$BUILDLOG" 2>&1  # dbsync requires PostgreSQL
		fi
	done
	if [ ".$HOSTED_GRAFANA" = '.Y' ]; then
		debug "Granting hosted Grafana IPs access to Prometheus port, $EXTERNAL_PROMETHEUS_PORT"
	    GRAFANAIPLIST="${BUILDDIR}/grafana-iplist.json"
		[ -s "$GRAFANAIPLIST" ] && mv -f "$GRAFANAIPLIST" "${GRAFANAIPLIST}.old"
		if ! $WGET -S 'https://grafana.com/api/hosted-grafana/source-ips' -O "$GRAFANAIPLIST" 1>> "$BUILDLOG" 2>&1; then
			[[ -s "${GRAFANAIPLIST}.old" ]] \
				|| err_exit 27 "$0: Grafana IP download failed, and no cached Grafana IP list; aborting"
			mv -f "${GRAFANAIPLIST}.old" "$GRAFANAIPLIST" 
		fi
		for GRAFIP in $(jq -c '.[]' "$GRAFANAIPLIST" | sed 's/^"\(.*\)"$/\1/g'); do
			ufw allow proto tcp from "$GRAFIP" to any port "$EXTERNAL_PROMETHEUS_PORT" 1>> "$BUILDLOG" 2>&1 \
				|| err_exit 10 "$0: Aborting; failed to add firewall rule: ufw allow proto tcp from $GRAFIP to any port $EXTERNAL_PROMETHEUS_PORT"
		done
	fi
	debug "Allowing all traffic to cardano-node port, $LISTENPORT/tcp"
	# Assume cardano-node is publicly available, so don't restrict 
	ufw allow "$LISTENPORT/tcp"  1>> "$BUILDLOG" 2>&1
	ufw --force enable           1>> "$BUILDLOG" 2>&1
	debug "Firewall enabled; to check the configuration: 'ufw status numbered'"
	# [ -z "$DEBUG" ] || ufw status numbered  # show what's going on

	# Add RDP service if INSTALLRDP is Y
	#
	if [ ".$INSTALLRDP" = ".Y" ]; then
	    debug "Setting up RDP; please check setup by hand when done"
		$APTINSTALLER install xrdp     1>> "$BUILDLOG" 2>&1
		$APTINSTALLER install tasksel  1>> "$BUILDLOG" 2>&1
		tasksel install ubuntu-desktop 1>> "$BUILDLOG" 2>&1
		systemctl enable xrdp          1>> "$BUILDLOG" 2>&1
		if [ ".$START_SERVICES" != '.N' ]; then
			systemctl start xrdp		1>> "$BUILDLOG" 2>&1; sleep 3
			systemctl is-active xrdp 	1> /dev/null \
				|| err_exit 136 "$0: Problem enabling (or starting) xrdp; aborting (run 'systemctl status xrdp')"
		fi
		RUID=$(who | awk 'FNR == 1 {print $1}')
		RUSER_UID=$(id -u ${RUID})
		sudo -u "${RUID}" DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/${RUSER_UID}/bus" gsettings set org.gnome.settings-daemon.plugins.power sleep-inactive-battery-type 'nothing' 2>> "$BUILDLOG"
		sudo -u "${RUID}" DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/${RUSER_UID}/bus" gsettings set org.gnome.settings-daemon.plugins.power sleep-inactive-ac-type 'nothing'      2>> "$BUILDLOG"
		dconf update 2>> "$BUILDLOG"
		systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target 1>> "$BUILDLOG" 2>&1
		ufw allow from "$MY_SUBNETS" to any port 3389 1>> "$BUILDLOG" 2>&1
	fi
fi

# Fail2ban setup
#
if [ -s '/etc/fail2ban/filter.d/cardano.conf' ]; then
	debug 'Fail2ban configured; not creating: /etc/fail2ban/{jail.d/cardano.conf,filter.d/cardano.conf}'
else
	cat <<-_EOF > '/etc/fail2ban/jail.d/nginx-limit-req.conf'
		[nginx-limit-req]
		enabled = true
		filter = nginx-limit-req
		action = iptables-multiport[name=ReqLimit, port="http,https", protocol=tcp]
		logpath = %(nginx_error_log)s
		findtime = 180
		maxretry = 30
		bantime = 3666
	_EOF
	cat <<-_EOF > '/etc/fail2ban/filter.d/nginx-limit-req.conf'
		[Definition]
		failregex = limiting requests, excess:.* by zone.*client: <HOST>
		ignoreregex =
	_EOF
	debug 'Creating Fail2ban files: /etc/fail2ban/{jail.d/cardano.conf,filter.d/cardano.conf}'
	cat <<-_EOF > '/etc/fail2ban/jail.d/cardano.conf'
		# service name
		[cardano-node]
		# turn on /off
		enabled  = true
		# ports to ban (numeric or text)
		port     = $LISTENPORT
		# filter file basename (/etc/fail2ban/filter.d/cardano.conf)
		filter   = cardano
		# file to parse
		logpath  = /var/log/syslog
		# How many retries (maxretry) in how many seconds (findtime)
		maxretry = 3
		findtime = 180
		# ban time in seconds
		bantime = 3666
	_EOF
	cat <<-_EOF > '/etc/fail2ban/filter.d/cardano.conf'
		[Definition]
		#Theses regex expressions capture nodes that are not on the latest fork and also; <HOST> is a regex macro
		#nodes from other networks (testnets)
		failregex = ^.*HardForkEncoderDisabledEra.*"address":"<HOST>:.*$
			^.*version data mismatch.*"address":"<HOST>:.*$
			^.*"address":"<HOST>:.*version data mismatch.*$
	_EOF
fi
if [ ".$START_SERVICES" != '.N' ]; then
	debug "Checking fail2ban status (will squawk if NOT OK); please also leverage ISP DDOS protection"
	systemctl restart fail2ban		1>> "$BUILDLOG" 2>&1;	sleep 3
	systemctl is-active fail2ban	1> /dev/null \
		|| err_exit 134 "$0: Problem with fail2ban service; aborting (run 'systemctl status fail2ban')"
fi

# Set up Prometheus
#
cd "$BUILDDIR"
OPTCARDANO_DIR='/opt/cardano'
if [ -d "$OPTCARDANO_DIR" ]; then
	: already created
else
	debug "Creating /opt/cardano working monitoring, and general Cardano, directory"
	mkdir -p "$OPTCARDANO_DIR"								1>> "$BUILDLOG" 2>&1
    chown -R root.$INSTALL_USER "$OPTCARDANO_DIR"			 		1>> "$BUILDLOG" 2>&1
	find "$OPTCARDANO_DIR" -type d -exec chmod "2755" {} \;	1>> "$BUILDLOG" 2>&1
fi
PROMETHEUS_DIR="$OPTCARDANO_DIR/monitoring/prometheus"
useradd prometheus -s /sbin/nologin						1>> "$BUILDLOG" 2>&1
if [ -e "$PROMETHEUS_DIR/logs" ] && [ -e "$PROMETHEUS_DIR/data" ]; then
	: do nothing
else
	debug "Creating $PROMETHEUS_DIR/{data,logs} directories, group=prometheus"
	mkdir -p "$PROMETHEUS_DIR/data"	"$PROMETHEUS_DIR/logs"	1>> "$BUILDLOG" 2>&1
    chown -R root.$INSTALL_USER "$PROMETHEUS_DIR"			1>> "$BUILDLOG" 2>&1
	find "$PROMETHEUS_DIR" -type d -exec chmod "2755" {} \;	1>> "$BUILDLOG" 2>&1
	chgrp -R prometheus "$PROMETHEUS_DIR/data"	"$PROMETHEUS_DIR/logs"	1>> "$BUILDLOG" 2>&1
	chmod -R g+w "$PROMETHEUS_DIR/data" "$PROMETHEUS_DIR/logs"			1>> "$BUILDLOG" 2>&1	# Prometheus needs to write
fi
cd "$BUILDDIR"
if download_github_code "$BUILDDIR" "$INSTALLDIR" 'https://github.com/prometheus/prometheus' "$SKIP_RECOMPILE" "$BUILDLOG" "$PROMETHEUS_DIR"; then
	if ischroot && ! command -v 'go' 1>> "$BUILDLOG" 2>&1; then
		debug "Skipping prometheus rebuild; we're in a chroot and 'go' isn't installed"
	else
		cd './prometheus'
		debug "Building and installing prometheus"
		$MAKE clean						1>> "$BUILDLOG" 2>&1
		pushd './web/ui/react-app'		1>> "$BUILDLOG" 2>&1
		rm -rf node_modules				1>> "$BUILDLOG" 2>&1
		npm uninstall node-sass -g		1>> "$BUILDLOG" 2>&1
		node cache clean --force		1>> "$BUILDLOG" 2>&1
		node install node-sass --force	1>> "$BUILDLOG" 2>&1
		popd							1>> "$BUILDLOG" 2>&1
		$MAKE build						1>> "$BUILDLOG" 2>&1 \
			|| err_exit 21 "Failed to build Prometheus prometheus; see ${BUILDDIR}/prometheus"
		cp -f prometheus promtool "$PROMETHEUS_DIR/"	1>> "$BUILDLOG" 2>&1
	fi
fi

if [ ".$DONT_OVERWRITE" = '.Y' ] && [[ -f "${PROMETHEUS_DIR}/nginx-htpasswd" ]]
then
	debug "Skipping nginx cert, config and Prometheus config file remake (drop -d to force)"
else
	openssl req -x509 -newkey rsa:4096 -nodes -days 999 \
		-keyout "${PROMETHEUS_DIR}/nginx-${EXTERNAL_HOSTNAME}.key" \
		-out "${PROMETHEUS_DIR}/nginx-${EXTERNAL_HOSTNAME}.crt" 1>> "$BUILDLOG" 2>&1 <<- _EOF
			US
			Minnesota
			Rural
			Local Company
			Local Company
			$EXTERNAL_HOSTNAME
			self-signed-cert@local-company.local
		_EOF
	NGINX_CONF_DIR='/usr/local/etc/nginx/conf.d'
	debug "Writing nginx reverse proxy conf for http://127.0.0.1:$PREPROXY_PROMETHEUS_PORT/"
	[ -f "${PROMETHEUS_DIR}/nginx-htpasswd" ] \
		|| echo -n -e "stats\n$(openssl rand -base64 14)" > "${PROMETHEUS_DIR}/nginx-passwd-cleartext.txt"
	chmod o-rwx "${PROMETHEUS_DIR}/nginx-passwd-cleartext.txt"
	htpasswd -b -c "${PROMETHEUS_DIR}/nginx-htpasswd" stats "$(cat ${PROMETHEUS_DIR}/nginx-passwd-cleartext.txt | tail -1 | sed 's/\n$//')" 1>> "$BUILDLOG" 2>&1
	debug "Prometheus (via nginx) credentials: username, stats; pass, $(cat ${PROMETHEUS_DIR}/nginx-passwd-cleartext.txt | tail -1 | sed 's/\n$//')"
	[ -d "$NGINX_CONF_DIR" ] || NGINX_CONF_DIR='/etc/nginx/conf.d'
	cat <<- _EOF > "$NGINX_CONF_DIR/nginx-${EXTERNAL_HOSTNAME}.conf" 
		limit_req_zone \$binary_remote_addr zone=one:3m rate=1r/s;
		server {
		    listen              $EXTERNAL_PROMETHEUS_PORT ssl;
		    server_name         example.com;
		    ssl_certificate     ${PROMETHEUS_DIR}/nginx-${EXTERNAL_HOSTNAME}.crt;
		    ssl_certificate_key ${PROMETHEUS_DIR}/nginx-${EXTERNAL_HOSTNAME}.key;

		    location / {
		        auth_basic "Restricted Content";
		        auth_basic_user_file ${PROMETHEUS_DIR}/nginx-htpasswd;
		        proxy_pass http://127.0.0.1:$PREPROXY_PROMETHEUS_PORT/;
				limit_req zone=one burst=5;
		    }
		}
	_EOF
	cat  <<- _EOF > "$PROMETHEUS_DIR/prometheus-cardano.yaml"
		global:
		  scrape_interval:     15s
		  query_log_file: $PROMETHEUS_DIR/logs/query.log
		  external_labels:
		    monitor: 'codelab-monitor'

		scrape_configs:
		  - job_name: 'cardano_node' # To scrape data from the cardano node
		    scrape_interval: 5s
		    static_configs:
		    - targets: ['$CARDANO_PROMETHEUS_LISTEN:$CARDANO_PROMETHEUS_PORT']
		  - job_name: 'node_exporter' # To scrape data from a node exporter - linux host metrics
		    scrape_interval: 5s
		    static_configs:
		    - targets: ['$EXTERNAL_NODE_EXPORTER_LISTEN:$EXTERNAL_NODE_EXPORTER_PORT']
	_EOF
	debug "Creating prometheus.service file; will listen on $PREPROXY_PROMETHEUS_LISTEN:$PREPROXY_PROMETHEUS_PORT"
	cat  <<- _EOF > '/etc/systemd/system/prometheus.service'
		[Unit]
		Description=Prometheus Server
		Documentation=https://prometheus.io/docs/introduction/overview/
		After=network-online.target

		[Service]
		User=prometheus
		Restart=on-failure
		ExecStart=$PROMETHEUS_DIR/prometheus \
		    --config.file=$PROMETHEUS_DIR/prometheus-cardano.yaml \
		    --storage.tsdb.path=$PROMETHEUS_DIR/data \
		    --web.listen-address=$PREPROXY_PROMETHEUS_LISTEN:$PREPROXY_PROMETHEUS_PORT \
		    --web.external-url=https://${EXTERNAL_HOSTNAME}:${EXTERNAL_PROMETHEUS_PORT}/ \
		    --web.route-prefix="/"
		WorkingDirectory=$PROMETHEUS_DIR
		RestartSec=6s
		LimitNOFILE=10000

		[Install]
		WantedBy=multi-user.target
	_EOF
fi
systemctl daemon-reload			1>> "$BUILDLOG" 2>&1
systemctl enable prometheus		1>> "$BUILDLOG" 2>&1
systemctl enable nginx			1>> "$BUILDLOG" 2>&1
if [ ".$START_SERVICES" != '.N' ]; then
	debug "Starting prometheus service (for use with Grafana on another host)"
	systemctl start prometheus		1>> "$BUILDLOG" 2>&1; sleep 3
	systemctl is-active prometheus	1> /dev/null \
		|| err_exit 37 "$0: Problem enabling (or starting) prometheus service; aborting (run 'systemctl status prometheus')"
	systemctl start nginx		1>> "$BUILDLOG" 2>&1; sleep 3
	systemctl is-active nginx	1> /dev/null \
		|| err_exit 38 "$0: Problem enabling (or starting) nginx service; aborting (run 'systemctl status nginx')"
fi

# Set up node_exporter
#
debug "Installing (and building, if -x was not supplied) node_exporter"
cd "$BUILDDIR"
NODE_EXPORTER_DIR="$OPTCARDANO_DIR/monitoring/exporters"
useradd node_exporter -s /sbin/nologin					1>> "$BUILDLOG" 2>&1
if [ -e "$NODE_EXPORTER_DIR" ]; then
	: do nothing
else
	mkdir -p "$NODE_EXPORTER_DIR"								1>> "$BUILDLOG" 2>&1
    chown -R root.$INSTALL_USER "$NODE_EXPORTER_DIR"			1>> "$BUILDLOG" 2>&1
	find "$NODE_EXPORTER_DIR" -type d -exec chmod "2755" {} \;	1>> "$BUILDLOG" 2>&1
fi
if download_github_code "$BUILDDIR" "$INSTALLDIR" 'https://github.com/prometheus/node_exporter' "$SKIP_RECOMPILE" "$BUILDLOG" "$NODE_EXPORTER_DIR"; then
	cd './node_exporter'
	$MAKE common-all	1>> "$BUILDLOG" 2>&1 \
		|| err_exit 21 "Failed to build Prometheus node_exporter; see ${BUILDDIR}/node_exporter"
fi
systemctl stop node_exporter							1>> "$BUILDLOG" 2>&1

cp -f $(find "$BUILDDIR/node_exporter/" -type f -name 'node_exporter' ! -path '*OLD*') "$NODE_EXPORTER_DIR/node_exporter" 1>> "$BUILDLOG" 2>&1
if [ ".$DONT_OVERWRITE" = '.Y' ] && [ -f '/etc/systemd/system/node_exporter.service' ]
then
	debug "Skipping node_exporter service file remake (drop -d to force)"
else
	cat <<- _EOF > '/etc/systemd/system/node_exporter.service'
		[Unit]
		Description=Node Exporter
		Wants=network-online.target
		After=network-online.target

		[Service]
		User=node_exporter
		Restart=on-failure
		ExecStart=$NODE_EXPORTER_DIR/node_exporter \
		    --web.listen-address=${EXTERNAL_NODE_EXPORTER_LISTEN}:${EXTERNAL_NODE_EXPORTER_PORT}
		WorkingDirectory=$NODE_EXPORTER_DIR
		RestartSec=6s
		LimitNOFILE=3500

		[Install]
		WantedBy=multi-user.target
	_EOF
fi
systemctl daemon-reload			1>> "$BUILDLOG" 2>&1
systemctl enable node_exporter	1>> "$BUILDLOG" 2>&1
if [ ".$START_SERVICES" != '.N' ]; then
	debug "Starting node_exporter service (Prometheus will read data from here)"
	systemctl start node_exporter		1>> "$BUILDLOG" 2>&1; sleep 3
	systemctl is-active node_exporter	1> /dev/null \
		|| err_exit 37 "$0: Problem enabling (or starting) node_exporter service; aborting (run 'systemctl status node_exporter')"
	systemctl reload-or-restart prometheus	1>> "$BUILDLOG" 2>&1; 
	systemctl reload-or-restart nginx		1>> "$BUILDLOG" 2>&1; 
fi

# Add hidden WiFi network if -h <network SSID> was supplied; I don't recommend WiFi except for setup
#
if [ ".$HIDDENWIFI" != '.' ]; then
    debug "Setting up hidden WiFi network, $HIDDENWIFI; please check by hand when done"
	if [ -f "$WPA_SUPPLICANT" ]; then
		: do nothing
	else
		$APTINSTALLER install wpasupplicant 1>> "$BUILDLOG" 2>&1
		cat <<- _EOF > "$WPA_SUPPLICANT"
			country=US
			ctrl_interface=DIR=/var/run/wpa_supplicant GROUP=netdev
			update_config=1
				
		_EOF
	fi
	if egrep -q '^[	 ]*ssid="$HIDDENWIFI"' "$WPA_SUPPLICANT"; then
		: do nothing
	else
		cat <<- _EOF >> "$WPA_SUPPLICANT"

			network={
			    ssid="$HIDDENWIFI"
			    scan_ssid=1
			    psk="$HIDDENWIFIPASSWORD"
			    key_mgmt=WPA-PSK
			}

		_EOF
	fi
	#
	# Enable WiFi
	#
	WLAN=$(ls /sys/class/net | egrep wlan)
	if [ -f "/etc/systemd/system/network-wireless@.service" ]; then
		: do nothing
	else
		cat <<- _EOF >> "/etc/systemd/system/network-wireless@.service"
			[Unit]
			Description=Wireless network connectivity (%i)
			Wants=network.target
			Before=network.target
			BindsTo=sys-subsystem-net-devices-%i.device
			After=sys-subsystem-net-devices-%i.device

			[Service]
			Type=oneshot
			RemainAfterExit=yes

			ExecStart=/usr/sbin/ip link set dev %i up
			ExecStart=/usr/sbin/wpa_supplicant -B -i %i -c /etc/wpa_supplicant/wpa_supplicant.conf
			ExecStart=/usr/sbin/dhclient %i

			ExecStop=/usr/sbin/ip link set dev %i down

			[Install]
			WantedBy=multi-user.target

		_EOF
		ln -s "/etc/systemd/system/network-wireless@.service" \
			"/etc/systemd/system/multi-user.target.wants/network-wireless@${WLAN}.service" \
			    1>> "$BUILDLOG"
	fi
	systemctl daemon-reload                   1>> "$BUILDLOG"
	systemctl enable wpa_supplicant.service   1>> "$BUILDLOG"
	if [ ".$START_SERVICES" != '.N' ]; then
		systemctl start wpa_supplicant.service		1>> "$BUILDLOG" 2>&1; sleep 3
		systemctl is-active wpa_supplicant.service	1> /dev/null \
			|| err_exit 137 "$0: Problem enabling (or starting) wpa_supplicant.service service; aborting (run 'systemctl status wpa_supplicant.service')"
		# renew DHCP leases
		dhclient "$WLAN" 1>> "$BUILDLOG" 2>&1
	fi
fi

# DHCP to a specifi VLAN if asked (e.g., -v 5 for VLAN.5); disable other interfaces
#
if [ ".$VLAN_NUMBER" != '.' ]; then
    NETPLAN_FILE=$(egrep -l eth0 /etc/netplan/* | head -1)
	if [ ".$NETPLAN_FILE" = '.' ] || egrep -q 'vlans:' "$NETPLAN_FILE"; then
		debug "Skipping VLAN.$VLAN_NUMBER configuration; $NETPLAN_FILE missing, or has VLANs; edit manually."
	else
    	sed -i "$NETPLAN_FILE" -e '/eth0:/,/wlan0:|vlans:/ { s|^\([ 	]*dhcp4:[ 	]*\)true|\1false|gi }'
		cat <<- _EOF >> "$NETPLAN_FILE"
			    vlans:
			        vlan$VLAN_NUMBER:
			            id: $VLAN_NUMBER
			            link: eth0
			            dhcp4: true
		_EOF
    	echo "Configuring eth0 for VLAN.${VLAN_NUMBER}; check by hand and run 'netplan apply' (addresses may change!)" 1>&2
	fi
fi

# Make sure we have at least some swap
#
FSTABFILE='/etc/fstab'
SYSCONFIGFILE='/etc/sysctl.conf'
if [ $(swapon --show 2> /dev/null | wc -l) -eq 0 ] || ischroot; then
	SWAPFILE='/var/swapfile'
	if [ -e "$SWAPFILE" ] && [ "$(du -k /var/swapfile | cut -f1)" -ge 12000000 ]; then
		debug "Swap file (size >= 12G) already created; skipping"
	else
		ischroot || swapoff "$SWAPFILE"	1>> "$BUILDLOG" 2>&1
		debug "Allocating 12G swapfile, $SWAPFILE"
		fallocate -l 12G "$SWAPFILE"	1>> "$BUILDLOG" 2>&1
		chmod 0600 "$SWAPFILE"			1>> "$BUILDLOG" 2>&1
		mkswap "$SWAPFILE"				1>> "$BUILDLOG" 2>&1
		ischroot || swapon "$SWAPFILE"	1>> "$BUILDLOG" 2>&1 \
			|| err_exit 32 "$0: Can't enable swap: 'swapon $SWAPFILE'; aborting"
	fi
	if egrep -qi 'swap' "$FSTABFILE"; then
		debug "$FSTABFILE already mounts swap file; skipping"
	else
		debug "Adding swap line to $FSTABFILE: $SWAPFILE none swap sw 0 0"
		echo "$SWAPFILE    none    swap    sw    0    0" >> "$FSTABFILE"
	fi
	if egrep -qi "^ *vm\.swappiness *=" "$SYSCONFIGFILE"; then
		debug "$SYSCONFIGFILE already has vm.swappiness set; leaving sysconfig file alone"
	else
		debug "Upping system swappiness in sysconfig file, $SYSCONFIGFILE"
		echo -e "\n# Increase swappiness - actually use swap\nvm.swappiness=10\nvm.vfs_cache_pressure=50" >> "$SYSCONFIGFILE"
	fi
fi

# Secure shared memory
#
if egrep -qi 'tmpfs.*/run/shm' "$FSTABFILE"; then
	debug "$FSTABFILE already references tmpfs /run/shm; skipping modification"
else
	debug "Restricting tmpfs shared-memory use via $FSTABFILE: tmpfs /run/shm tmpfs ro,noexec,nosuid 0 0"
	echo "tmpfs    /run/shm    tmpfs    ro,noexec,nosuid    0 0" >> "$FSTABFILE"
fi

# Use faster network congestion and processing algorithm
#
if egrep -qi "net.ipv4.tcp_congestion_control" "$SYSCONFIGFILE"; then
	debug "$SYSCONFIGFILE already has Bottleneck Bandwidth and RTT enabled; leaving $SYSCONFIGFILE file alone"
else
	debug "Turning on Bottleneck Bandwidth and RTT in sysconfig file, $SYSCONFIGFILE"
	echo -e "\n# Use Google's congestion control algorithm\nnet.core.default_qdisc = fq\nnet.ipv4.tcp_congestion_control = bbr\n# net.ipv4.tcp_congestion_control=htcp" >> "$SYSCONFIGFILE"
fi

# Add cardano user (or whatever install user is used) and lock password
#
debug "Checking and (if need be) making install user: ${INSTALL_USER}"
id "$INSTALL_USER" 1>> "$BUILDLOG"  2>&1 \
    || useradd -m -U -s /bin/bash -d "/home/$INSTALL_USER" "$INSTALL_USER"	1>> "$BUILDLOG"
# The account for the install user (which will run cardano-node) should be locked
usermod -a -G users "$INSTALL_USER" -s /usr/sbin/nologin					1>> "$BUILDLOG" 2>&1
passwd -l "$INSTALL_USER"													1>> "$BUILDLOG"
(stat "/home/${INSTALL_USER}" --format '%A' | egrep -q '\---$') \
	|| (chown $INSTALL_USER.$INSTALL_USER "/home/${INSTALL_USER}"; chmod o-rwx "/home/${INSTALL_USER}")

# Increase cardano-user open-file limits
#
LIMITSFILE='/etc/security/limits.conf'
if egrep -qi "$INSTALL_USER" "$LIMITSFILE"; then
	debug "$LIMITSFILE already references $INSTALL_USER user; skipping limit increase"
else
	debug "Setting open-file limits for $INSTALL_USER user to 800000 (soft) and 1048576 (hard)"
	echo -e "$INSTALL_USER soft nofile 800000\n$INSTALL_USER hard nofile 1048576" >> "$LIMITSFILE"
fi

# Install GHC, cabal
#
cd "$BUILDDIR"
debug "Downloading: ghc-${GHCVERSION}"
$WGET "http://downloads.haskell.org/~ghc/${GHCVERSION}/ghc-${GHCVERSION}-${GHCARCHITECTURE}-${GHCOS}-linux.tar.xz" -O "ghc-${GHCVERSION}-${GHCARCHITECTURE}-${GHCOS}-linux.tar.xz"
if which ghc 1>> "$BUILDLOG" 2>&1; then
	if dpkg --compare-versions "$GHCVERSION" 'gt' $(ghc --version | awk '{ print $(NF) }' 2> /dev/null); then
		debug "Requested GHC version $GHCVERSION > observed, $(ghc --version | awk '{ print $(NF) }' 2> /dev/null), rebuilding"
		SKIP_RECOMPILE=''
	fi
else
	SKIP_RECOMPILE=''
fi
if [ ".$SKIP_RECOMPILE" != '.Y' ]; then
    debug "Building: ghc-${GHCVERSION}"
	'rm' -rf "ghc-${GHCVERSION}"
	tar -xf "ghc-${GHCVERSION}-${GHCARCHITECTURE}-${GHCOS}-linux.tar.xz" 1>> "$BUILDLOG"
	cd "ghc-${GHCVERSION}"
	debug "Running: ./configure CONF_CC_OPTS_STAGE2=\"$GCCMARMARG $GHC_GCC_ARCH\" CFLAGS=\"$GCCMARMARG $GHC_GCC_ARCH\""
	./configure CONF_CC_OPTS_STAGE2="$GCCMARMARG $GHC_GCC_ARCH" CFLAGS="$GCCMARMARG $GHC_GCC_ARCH" 1>> "$BUILDLOG"
	debug "Installing: ghc-${GHCVERSION}"
	$MAKE install 1>> "$BUILDLOG"
fi
# Fall back to GHCUP install if there is no GHC executable
which ghc 1>> "$BUILDLOG" 2>&1 || do_ghcup_install

# Now do cabal; we'll pull binaries in this case
#
cd "$BUILDDIR"
if [ -z "$GHCUP_INSTALL_PATH" ]; then  # If GHCUP was not used, we still need to build cabal
	if download_github_code "$BUILDDIR" "$INSTALLDIR" 'https://github.com/haskell/cabal' "$SKIP_RECOMPILE" "$BUILDLOG" "$INSTALLDIR" "$CABAL_VERSION"; then
		STILL_NEED_CABAL_BINARY='Y' 
		if [ -x "$CABAL" ]; then
			debug "Compiling new cabal using existing $CABAL; can be slow; must down any running node"
			if systemctl list-unit-files --type=service --state=enabled | egrep -q 'cardano-node'; then
				systemctl stop cardano-node  	1>> "$BUILDLOG" 2>&1
				# Disable in case we're doing a backup; backup should come up w/out cardano-node enabled
				[ ".$START_SERVICES" = '.N' ] && systemctl disable cardano-node 	1>> "$BUILDLOG" 2>&1
			fi
			cd './cabal'						1>> "$BUILDLOG" 2>&1
			git reset --hard					1>> "$BUILDLOG" 2>&1  # Do this again, even though download_github_code did it
			git pull							1>> "$BUILDLOG" 2>&1
			$CABAL update						1>> "$BUILDLOG" 2>&1
			if $CABAL install --project-file=cabal.project.release --overwrite-policy=always cabal-install 1>> "$BUILDLOG" 2>&1; then
				cp "$HOME/.cabal/bin/cabal" "$CABAL" 1>> "$BUILDLOG" 2>&1 \
					|| cp -f $(find "$BUILDDIR/cabal/bootstrap" -type f -name cabal ! -path '*OLD*') "$CABAL" 1>> "$BUILDLOG" 2>&1
				STILL_NEED_CABAL_BINARY='N'
			fi
		fi
		if [ ".$STILL_NEED_CABAL_BINARY" = '.Y' ]; then
			if $WGET "${CABALDOWNLOADPREFIX}-${CABALARCHITECTURE}-${CABAL_OS}.tar.xz" -O "cabal-${CABALARCHITECTURE}-${CABAL_OS}.tar.xz" 1>> "$BUILDLOG" 2>&1; then
				debug "Downloaded for unpacking: ${CABALDOWNLOADPREFIX}-${CABALARCHITECTURE}-${CABAL_OS}.tar.xz"
				tar -xf "cabal-${CABALARCHITECTURE}-${CABAL_OS}.tar.xz" 1>> "$BUILDLOG" \
					&& cp -f ./cabal "$CABAL"	1>> "$BUILDLOG" 2>&1
			else
				debug "Can't download cabal from ${CABALDOWNLOADPREFIX}-${CABALARCHITECTURE}-${CABAL_OS}.tar.xz"
				do_ghcup_install
				STILL_NEED_CABAL_BINARY='N'
			fi
		fi
	fi
	if [[ ! -x "$CABAL" ]]; then
		debug "No $CABAL executable found; correcting - using GHCUP"
		do_ghcup_install || err_exit 41 "$0: All attempts at installing cabal have failed; aborting"
	fi
	chown root.root "$CABAL"	1>> "$BUILDLOG" 2>&1
	chmod 0755 "$CABAL"			1>> "$BUILDLOG" 2>&1
else
	[ ".$SKIP_RECOMPILE" = '.Y' ] \
		|| debug "Skipping cabal install checks; already done via GHCUP"
fi

if [ ".$SKIP_RECOMPILE" != '.Y' ]; then
	debug "Updating cabal database: '$CABAL update'"
	if $CABAL update 1>> "$BUILDLOG" 2>&1; then
		debug "Successfully updated $CABAL database"
	else
		debug "Working around bug in $CABAL; rebuilding $HOME/.cabal"
		pushd ~ 1>> "$BUILDLOG" 2>&1 # Work around bug in cabal
		'rm' -rf $HOME/.cabal
		($CABAL update 2>&1 | tee -a "$BUILDLOG") || err_exit 67 "$0: Failed to run '$CABAL update'; aborting"
		popd 	1>> "$BUILDLOG" 2>&1
	fi
fi

# Install wacky IOHK-recommended version of libsodium unless told to use a different -w $LIBSODIUM_VERSION
#
cd "$BUILDDIR"
if download_github_code "$BUILDDIR" "$INSTALLDIR" "${IOHKREPO}/libsodium" "$SKIP_RECOMPILE" "$BUILDLOG" '/usr/local/lib' '0'; then
	debug "Building and installing libsodium, version $LIBSODIUM_VERSION"
	cd './libsodium'					1>> "$BUILDLOG" 2>&1
	git checkout "$LIBSODIUM_VERSION"	1>> "$BUILDLOG" 2>&1 || err_exit 77 "$0: Failed to 'git checkout' libsodium version "$LIBSODIUM_VERSION"; aborting"
	git fetch							1>> "$BUILDLOG" 2>&1
	$MAKE clean							1>> "$BUILDLOG" 2>&1
	./autogen.sh 						1>> "$BUILDLOG" 2>&1
	./configure							1>> "$BUILDLOG" 2>&1
	$MAKE								1>> "$BUILDLOG" 2>&1
	$MAKE install						1>> "$BUILDLOG" 2>&1 \
		|| err_exit 78 "$0: Failed to build, install libsodium version "$LIBSODIUM_VERSION"; aborting"
fi
# Apparent problem with Debian on this front
if [ -f "/usr/local/lib/libsodium.so.23.3.0" ]; then
    [ -f "/usr/lib/libsodium.so.23" ] || \
		ln -s "/usr/local/lib/libsodium.so.23.3.0" "/usr/lib/libsodium.so.23"
fi

# Modify and source .bashrc file; save NODE_BUILD_NUM
#
NODE_BUILD_NUM=$($WGET -S -O- 'https://hydra.iohk.io/job/Cardano/cardano-node/cardano-deployment/latest-finished/download/1/index.html' 2>&1 | sed -n '/^ *[lL]ocation: / { s|^.*/build/\([^/]*\)/download.*$|\1|ip; q; }')
[ -z "$NODE_BUILD_NUM" ] && \
    (NODE_BUILD_NUM=$($WGET -S -O- "https://hydra.iohk.io/job/Cardano/iohk-nix/cardano-deployment/latest-finished/download/1/${BLOCKCHAINNETWORK}-byron-genesis.json" 2>&1 | sed -n '/^ *[lL]ocation: / { s|^.*/build/\([^/]*\)/download.*$|\1|ip; q; }') || \
		debug 49 "$0: Unable to fetch node build number; continuing anyway")
debug "NODE_BUILD_NUM discovered (used to fetch latest config files): $NODE_BUILD_NUM" 
for bashrcfile in "$HOME/.bashrc" "/home/${BUILD_USER}/.bashrc" "$INSTALLDIR/.bashrc"; do
	debug "Adding/updating LD_LIBRARY_PATH, etc. env vars in .bashrc file: $bashrcfile"
	if [ -f "$bashrcfile" ]; then
		: do nothing
	else 
		if [ -f '/etc/skel/.bashrc' ]; then
			cp -f /etc/skel/.bashrc "$bashrcfile"
			USEROWNER=$(echo "$bashrcfile" | cut -f3 -d/)
			chown $USEROWNER.$USEROWNER "$bashrcfile"
			chmod 0640 "$bashrcfile"
		fi
	fi
	for envvar in 'LD_LIBRARY_PATH' 'PKG_CONFIG_PATH' 'NODE_HOME' 'NODE_CONFIG' 'NODE_BUILD_NUM' 'PATH' 'CARDANO_NODE_SOCKET_PATH'; do
		case "${envvar}" in
			'LD_LIBRARY_PATH'          ) SUBSTITUTION="\"/usr/local/lib:\${LD_LIBRARY_PATH}\"" ;;
			'PKG_CONFIG_PATH'          ) SUBSTITUTION="\"/usr/local/lib/pkgconfig:\${PKG_CONFIG_PATH}\"" ;;
			'NODE_HOME'                ) SUBSTITUTION="\"${INSTALLDIR}\"" ;;
			'NODE_FILES'               ) SUBSTITUTION="\"${$CARDANO_FILEDIR}\"" ;;
			'NODE_CONFIG'              ) SUBSTITUTION="\"${BLOCKCHAINNETWORK}\"" ;;
			'NODE_BUILD_NUM'           ) SUBSTITUTION="\"${NODE_BUILD_NUM}\"" ;;
			'PATH'                     ) SUBSTITUTION="\"${GHCUP_INSTALL_PATH}:/usr/local/bin:${INSTALLDIR}:\${PATH}\"" ;;
			'CARDANO_NODE_SOCKET_PATH' ) SUBSTITUTION="\"${INSTALLDIR}/sockets/${BLOCKCHAINNETWORK}-node.socket\"" ;;
			\? ) err_exit 91 "0: Coding error in environment variable case statement; aborting" ;;
		esac
		if egrep -q "^ *export  *${envvar} *=" "$bashrcfile"; then
		    # debug "Changing variable in $bashrcfile: export ${envvar}=.*$ -> export ${envvar}=${SUBSTITUTION}"
			sed -i "$bashrcfile" -e "s|^ *export  *\(${envvar}\) *=.*\$|export \1=${SUBSTITUTION}|g"
		else
		    # debug "Appending to $bashrcfile: ${envvar}=${SUBSTITUTION}" 
			echo "export ${envvar}=${SUBSTITUTION}" >> $bashrcfile
		fi
    done
done
. "/home/${BUILD_USER}/.bashrc"

# Install cardano-node
#
# BACKUP PREVIOUS SOURCES AND DOWNLOAD $CARDANONODE_VERSION
#
cd "$BUILDDIR"
[ -z "$CARDANONODE_VERSION" ] && CARDANONODE_VERSION=$(git_latest_release "${IOHKREPO}/cardano-node")
download_github_code "$BUILDDIR" "$INSTALLDIR" "${IOHKREPO}/cardano-node" "$SKIP_RECOMPILE" "$BUILDLOG" '' '' 'cardano-node'
cd "$BUILDDIR/cardano-node"
git clone "${IOHKREPO}/cardano-node"	1>> "$BUILDLOG" 2>&1
debug "Updating local copies of cardano-node remote git branches"
git fetch --all --recurse-submodules --tags	 --prune 1>> "$BUILDLOG" 2>&1
debug "Setting working cardano-node branch to: $CARDANOBRANCH (force with -U <branch>)"
git switch "$CARDANOBRANCH" 1>> "$BUILDLOG" 2>&1
if git checkout "$CARDANONODE_VERSION" 1>> "$BUILDLOG" 2>&1; then
	debug "Checked out cardano-node version $CARDANONODE_VERSION (force with -V <version>)"
else
	debug "Checkout failed; trying tags/$CARDANONODE_VERSION"
	if [[ "$CARDANONODE_VERSION" =~ ^[0-9]{1,2}\.[0-9]{1,3} ]]; then
		CARDANONODE_TAGGEDVERSION="tags/$CARDANONODE_VERSION"
		debug "Checking out tag: git checkout ${CARDANONODE_TAGGEDVERSION} (force with -V <version>)"
		git checkout "${CARDANONODE_TAGGEDVERSION}"	1>> "$BUILDLOG" 2>&1 \
			|| err_exit 79 "$0: Failed to 'git checkout $CARDANONODE_TAGGEDVERSION; aborting"
	fi
fi
git fetch	1>> "$BUILDLOG" 2>&1

# Set build options for cardano-node and cardano-cli
#
OBSERVED_CARDANO_NODE_VERSION=$("$INSTALLDIR/cardano-node" version | head -1 | awk '{ print $2 }')
if [ ".$SKIP_RECOMPILE" != '.Y' ] || [[ ! -x "$INSTALLDIR/cardano-node" ]] || [ ".${OBSERVED_CARDANO_NODE_VERSION}" != ".${CARDANONODE_VERSION}" ]; then
	debug "Building cardano-node; already installed version is ${OBSERVED_CARDANO_NODE_VERSION:-(not found)}"
	$CABAL clean 1>> "$BUILDLOG"  2>&1
	$CABAL configure -O0 -w "ghc-${GHCVERSION}" 1>> "$BUILDLOG"  2>&1
	'rm' -rf "${BUILDDIR}/cardano-node/dist-newstyle/build/x86_64-linux/ghc-${GHCVERSION}"
	echo -e "package cardano-crypto-praos\n flags: -external-libsodium-vrf" > "${BUILDDIR}/cabal.project.local"
	debug "Building all: '$CABAL build all' (cwd = `pwd`)"
	if $CABAL build all 1>> "$BUILDLOG" 2>&1; then
		: all good
	else
		if [ ".$DEBUG" = '.Y' ]; then
			# Do some more intense debugging if the build fails, with a more restrictive library search path
			debug "Failed to build cardano-node; setting LD_LIBRARY_PATH and PKG_CONFIG_PATH to specific /usr/local locations"
			LD_LIBRARY_PATH="/usr/local/lib"; 			EXPORT LD_LIBRARY_PATH
			PKG_CONFIG_PATH="/usr/local/lib/pkgconfig"; EXPORT PKG_CONFIG_PATH
			$CABAL build cardano-cli cardano-node 2>&1 \
				|| err_exit 88 "$0: Failed to build cardano-node; try rerunning or: 'strace $CABAL build cardano-cli cardano-node'"
			debug "Built cardano-node successfully with explicit LD_LIBRARY_PATH and PKG_CONFIG_PATH"
		else
			err_exit 87 "$0: Failed to build cardano-cli and cardano-node; aborting"
		fi
	fi
fi

# Stop the node so we can replace binaries or update config files
#
if systemctl list-unit-files --type=service --state=enabled | egrep -q 'cardano-node'; then
	debug "Stopping cardano-node service, if running, for potential config file or binary update" 
	systemctl stop cardano-node    1>> "$BUILDLOG" 2>&1
	# Disable cardano-node if we're running a backup; backup should come up with cardano-node disabled
	[ ".$START_SERVICES" = '.N' ] && systemctl disable cardano-node 1>> "$BUILDLOG" 2>&1
	# Just in case, kill everything run by the install user
	killall -s SIGINT  -u "$INSTALL_USER"  1>> "$BUILDLOG" 2>&1; sleep 10  # Wait a bit before delivering death blow
	killall -s SIGKILL -u "$INSTALL_USER"  1>> "$BUILDLOG" 2>&1
fi

# Copy new binaries into final position, in $INSTALLDIR
#
if [ ".$SKIP_RECOMPILE" != '.Y' ] || [[ ! -x "$INSTALLDIR/cardano-node" ]] || [ ".${OBSERVED_CARDANO_NODE_VERSION}" != ".${CARDANONODE_VERSION}" ]; then
	debug "(Re)installing binaries for cardano-node and cardano-cli" 
	$CABAL install --overwrite-policy=always --installdir "$INSTALLDIR" cardano-cli cardano-node 1>> "$BUILDLOG" 2>&1
    # If we recompiled or user wants new version, remove symlinks if they exist in prep for copying in new binaries
	mv -f "$INSTALLDIR/cardano-cli" "$INSTALLDIR/cardano-cli.OLD"	1>> "$BUILDLOG" 2>&1
	mv -f "$INSTALLDIR/cardano-node" "$INSTALLDIR/cardano-node.OLD"	1>> "$BUILDLOG" 2>&1
	if [ -x "$INSTALLDIR/cardano-node" ] && [ -x "$INSTALLDIR/cardano-cli" ] && [ ".${OBSERVED_CARDANO_NODE_VERSION}" = ".${CARDANONODE_VERSION}" ]; then
		: do nothing
	else
		cp -f $(find "$BUILDDIR" -type f -name cardano-cli ! -path '*OLD*') "$INSTALLDIR/cardano-cli" 1>> "$BUILDLOG" 2>&1 \
			|| { mv -f "$INSTALLDIR/cardano-cli.OLD" "$INSTALLDIR/cardano-cli"; err_exit 81 "Failed to build cardano-cli; aborting"; }
		cp -f $(find "$BUILDDIR" -type f -name cardano-node ! -path '*OLD*') "$INSTALLDIR/cardano-node" 1>> "$BUILDLOG" 2>&1 \
			|| { mv -f "$INSTALLDIR/cardano-node.OLD" "$INSTALLDIR/cardano-node"; err_exit 81 "Failed to build cardano-node; aborting"; }
	fi
	[ -x "$INSTALLDIR/cardano-node" ] || err_exit 147 "$0: Failed to install $INSTALLDIR/cardano-node; aborting"
	debug "Installed cardano-node version: $(${INSTALLDIR}/cardano-node version | head -1)"
	debug "Installed cardano-cli version: $(${INSTALLDIR}/cardano-node version | head -1)"
fi

# Set up directory structure in the $INSTALLDIR (OK if they exist already)
#
# Set owner of topology file here to root (will later set it back)
create_and_secure_installdir "$BLOCKCHAINNETWORK" "$INSTALLDIR" "$CARDANO_FILEDIR" "$CARDANO_DBDIR" "$CARDANO_PRIVDIR" "$CARDANO_SCRIPTDIR" "$CARDANO_SPOSDIR" "$INSTALL_USER" 'root'

LASTRUNFILE="$INSTALLDIR/logs/build-command-line-$(date '+%Y-%m-%d-%H:%M:%S').log"
echo -n "$SCRIPT_PATH/pi-cardano-node-setup.sh $@ # (not completed)" > $LASTRUNFILE

# Configure this server to fail over for another block-producing node if asked (-f <parent:port>)
#
CRONFILE='/etc/cron.d/cardano-failover'
if [ -z "$FAILOVER_PARENT" ]; then
	# Remove unneeded cron job
	debug "No parent-failover configured; removing cron file (if it exists): $CRONFILE"
	rm -f "$CRONFILE"		1>> "$BUILDLOG" 2>&1
	service cron reload 	1>> "$BUILDLOG" 2>&1
else
	if [ ".$SCRIPT_PATH" != '.' ] && [ -e "$SCRIPT_PATH/pi-cardano-heartbeat-failover.sh" ]; then
		debug "Copying heartbeat-failover script into position: $INSTALLDIR/pi-cardano-heartbeat-failover.sh"
		cp "$SCRIPT_PATH/pi-cardano-heartbeat-failover.sh" "$INSTALLDIR"
		chown root.$INSTALL_USER "$INSTALLDIR/pi-cardano-heartbeat-failover.sh"
		chmod 0750 "$INSTALLDIR/pi-cardano-heartbeat-failover.sh"
		PARENTADDR=$(echo "$FAILOVER_PARENT" | sed 's/^\[*\([^]]*\)\]*:[^.:]*$/\1/')	# Take out ip address part
		PARENTPORT=$(echo "$FAILOVER_PARENT" | sed 's/^\[*[^]]*\]*:\([^.:]*\)$/\1/')	# Take out port part
		if [ -z "$PARENTADDR" ]; then
			err_exit 71 "$0: Can't determine failover parent host/ip:port from supplied data: $FAILOVER_PARENT"
		else
			[ -z "$PARENTPORT" ] && debug "Defaulting failover parent port to 6000"
			sed -i "$INSTALLDIR/pi-cardano-heartbeat-failover.sh" \
				-e "s|^ *PARENTADDR=\"\([^\"]*\)\"|PARENTADDR=\"${PARENTADDR}\"|" \
				-e "s|^ *PARENTPORT=\"\([^\"]*\)\"|PARENTPORT=\"${PARENTPORT:-6000}\"|"
			# Add cron job
			debug "Adding cron job for heartbeat-failover script (runs every 2 min): "$CRONFILE""
			echo "*/2 * * * * cardano test -x $INSTALLDIR/pi-cardano-heartbeat-failover.sh && $INSTALLDIR/pi-cardano-heartbeat-failover.sh" > "$CRONFILE"
			service cron reload 1>> "$BUILDLOG" 2>&1
		fi
	else
		err_exit 72 "$0: Bad '-p $FAILOVER_PARENT'; can't find $SCRIPT_PATH/pi-cardano-heartbeat-failover.sh"
	fi
fi

# UPDATE mainnet-config.json and related files to latest version and start node
#
if [ ".$DONT_OVERWRITE" != '.Y' ]; then
    debug "Downloading new versions of various files, including: $CARDANO_FILEDIR/${BLOCKCHAINNETWORK}-config.json"
	cd "$INSTALLDIR"
	export EKG_PORT=$(jq -r .hasEKG "${CARDANO_FILEDIR}/${BLOCKCHAINNETWORK}-config.json"						2>> "$BUILDLOG")
	debug "Fetching json files from IOHK; starting with: https://hydra.iohk.io/build/${NODE_BUILD_NUM}/download/1/${BLOCKCHAINNETWORK}-config.json "
	$WGET "${GUILDREPO_RAW}/alpha/files/config-dbsync.json"														-O "${CARDANO_FILEDIR}/${BLOCKCHAINNETWORK}-dbsync.json"
	[[ -s "${CARDANO_FILEDIR}/${BLOCKCHAINNETWORK}-dbsync.json" ]] \
		|| $WGET "https://hydra.iohk.io/build/${NODE_BUILD_NUM}/download/1/${BLOCKCHAINNETWORK}-dbsync.json"	-O "${CARDANO_FILEDIR}/${BLOCKCHAINNETWORK}-dbsync.json"
	$WGET "https://hydra.iohk.io/build/${NODE_BUILD_NUM}/download/1/${BLOCKCHAINNETWORK}-config.json"			-O "${CARDANO_FILEDIR}/${BLOCKCHAINNETWORK}-config.json"
	$WGET "https://hydra.iohk.io/build/${NODE_BUILD_NUM}/download/1/${BLOCKCHAINNETWORK}-topology.json"			-O "${CARDANO_FILEDIR}/${BLOCKCHAINNETWORK}-topology.json"
	$WGET "https://hydra.iohk.io/build/${NODE_BUILD_NUM}/download/1/${BLOCKCHAINNETWORK}-byron-genesis.json"	-O "${CARDANO_FILEDIR}/${BLOCKCHAINNETWORK}-byron-genesis.json"
	$WGET "https://hydra.iohk.io/build/${NODE_BUILD_NUM}/download/1/${BLOCKCHAINNETWORK}-shelley-genesis.json"	-O "${CARDANO_FILEDIR}/${BLOCKCHAINNETWORK}-shelley-genesis.json"

	# Restoring previous parameters to the config file:
	if [ ".$EKG_PORT" != '.' ]; then 
		debug "Restoring old hasEKG value, setting Prometheus values, in dbsync.json and config.json files"
		jq .hasPrometheus[0]="\"${CARDANO_PROMETHEUS_LISTEN}\""  "${CARDANO_FILEDIR}/${BLOCKCHAINNETWORK}-dbsync.json" 2>> "$BUILDLOG" \
			|  sponge "$CARDANO_FILEDIR/${BLOCKCHAINNETWORK}-dbsync.json" 
		jq .hasPrometheus[1]="${CARDANO_PROMETHEUS_PORT}"        "${CARDANO_FILEDIR}/${BLOCKCHAINNETWORK}-dbsync.json" 2>> "$BUILDLOG" \
			|  sponge "$CARDANO_FILEDIR/${BLOCKCHAINNETWORK}-dbsync.json" 
		jq .hasEKG="${EKG_PORT}"                        		 "${CARDANO_FILEDIR}/${BLOCKCHAINNETWORK}-config.json" 2>> "$BUILDLOG" \
			|  sponge "$CARDANO_FILEDIR/${BLOCKCHAINNETWORK}-config.json" 
		jq .hasPrometheus[0]="\"${CARDANO_PROMETHEUS_LISTEN}\""  "${CARDANO_FILEDIR}/${BLOCKCHAINNETWORK}-config.json" 2>> "$BUILDLOG" \
			|  sponge "$CARDANO_FILEDIR/${BLOCKCHAINNETWORK}-config.json" 
		jq .hasPrometheus[1]="${CARDANO_PROMETHEUS_PORT}"        "${CARDANO_FILEDIR}/${BLOCKCHAINNETWORK}-config.json" 2>> "$BUILDLOG" \
			|  sponge "$CARDANO_FILEDIR/${BLOCKCHAINNETWORK}-config.json" 
	fi
	[ -s "$CARDANO_FILEDIR/${BLOCKCHAINNETWORK}-config.json" ] \
		|| err_exit 58 "0: Failed to download ${BLOCKCHAINNETWORK}-config.json from https://hydra.iohk.io/build/${NODE_BUILD_NUM}/download/1/"
	chown -R root.$INSTALL_USER "$CARDANO_FILEDIR/"*.json

	# Adjust files in various ways - turning off memory monitoring (kills performance in 1.25.1), turn on block fetch decision tracing
	debug "Setting TraceBlockFetchDecisions and allied configuration settings to 'true'"
	jq .TraceBlockFetchClient="true"				"${CARDANO_FILEDIR}/${BLOCKCHAINNETWORK}-config.json" 2> /dev/null | sponge "$CARDANO_FILEDIR/${BLOCKCHAINNETWORK}-config.json"
	jq .TraceBlockFetchDecisions="true"				"${CARDANO_FILEDIR}/${BLOCKCHAINNETWORK}-config.json" 2> /dev/null | sponge "$CARDANO_FILEDIR/${BLOCKCHAINNETWORK}-config.json"
	jq .TraceBlockFetchProtocol="true"				"${CARDANO_FILEDIR}/${BLOCKCHAINNETWORK}-config.json" 2> /dev/null | sponge "$CARDANO_FILEDIR/${BLOCKCHAINNETWORK}-config.json"
	jq .TraceBlockFetchProtocolSerialised="true"	"${CARDANO_FILEDIR}/${BLOCKCHAINNETWORK}-config.json" 2> /dev/null | sponge "$CARDANO_FILEDIR/${BLOCKCHAINNETWORK}-config.json"
	jq .TraceBlockFetchServer="true" 				"${CARDANO_FILEDIR}/${BLOCKCHAINNETWORK}-config.json" 2> /dev/null | sponge "$CARDANO_FILEDIR/${BLOCKCHAINNETWORK}-config.json"
	jq .TraceChainDb="true"							"${CARDANO_FILEDIR}/${BLOCKCHAINNETWORK}-config.json" 2> /dev/null | sponge "$CARDANO_FILEDIR/${BLOCKCHAINNETWORK}-config.json"
	TRACE_SETTING='false'
	[ "$LISTENPORT" -ge 6000 ] && [ ".$POOLNAME" != '.' ] && TRACE_SETTING='true'
	debug "Setting Trace{Forge,Mempool}=$TRACE_SETTING (if port > 6000 and pool name provided, assume BP [true]; otherwise relay [false])"
	jq .TraceForge="$TRACE_SETTING"					"${CARDANO_FILEDIR}/${BLOCKCHAINNETWORK}-config.json" 2> /dev/null | sponge "$CARDANO_FILEDIR/${BLOCKCHAINNETWORK}-config.json"
	jq .TraceMempool="$TRACE_SETTING" 				"${CARDANO_FILEDIR}/${BLOCKCHAINNETWORK}-config.json" 2> /dev/null | sponge "$CARDANO_FILEDIR/${BLOCKCHAINNETWORK}-config.json"
	
	# Set up startup script
	#
	SYSTEMSTARTUPSCRIPT="/etc/systemd/system/cardano-node.service"
	debug "(Re)creating cardano-node start-up script: $SYSTEMSTARTUPSCRIPT"
	[ -f "$NODE_CONFIG_FILE" ] || err_exit 28 "$0: Can't find config.yaml file, "$NODE_CONFIG_FILE"; aborting"
	#
	# Figure out where special keys, certs are and add them to startup script later on, if need be
	if [ ".$POOLNAME" != '.' ]; then
		POSSIBLE_POOL_CONFIGFILE="${CARDANO_PRIVDIR}/pool/${POOLNAME}/pool.config"
		if [ -f "$POSSIBLE_POOL_CONFIGFILE" ]; then
			GUILD_WALLET=$(jq ".rewardWallet" "$POSSIBLE_POOL_CONFIGFILE" 2> /dev/null | sed 's/^"//' | sed 's/"$//')
			if [ ".$GUILD_WALLET" != '.' ]; then
				debug "Taking data from Guild CNode Tool wallet in: ${CARDANO_PRIVDIR}/wallet/${GUILD_WALLET}"
				cp -f "${CARDANO_PRIVDIR}/pool/${POOLNAME}/hot.skey" "$CARDANO_PRIVDIR/kes.skey"
				cp -f "${CARDANO_PRIVDIR}/pool/${POOLNAME}/vrf.skey" "$CARDANO_PRIVDIR/vrf.skey"
				cp -f "${CARDANO_PRIVDIR}/pool/${POOLNAME}/op.cert" "$CARDANO_PRIVDIR/node.cert"
			else
				err_exit 131 "Can't find guild wallet: ${CARDANO_PRIVDIR}/wallet/${GUILD_WALLET}; aborting"
			fi
		fi
	fi
	CERTKEYARGS=''
	KEYCOUNT=0
	[ -s "$CARDANO_PRIVDIR/kes.skey" ]  && KEYCOUNT=$(expr "$KEYCOUNT" + 1)
	[ -s "$CARDANO_PRIVDIR/vrf.skey" ]  && KEYCOUNT=$(expr "$KEYCOUNT" + 1)
	[ -s "$CARDANO_PRIVDIR/node.cert" ] && KEYCOUNT=$(expr "$KEYCOUNT" + 1)
	if [ "${LISTENPORT}" -ge 6000 ] && [ ".$POOLNAME" != '.' ]; then
		# Assuming we're a block producer if -p <LISTENPORT> is >= 6000 and we have a pool name
		if [ "$KEYCOUNT" -ge 3 ]; then
			CERTKEYARGS="--shelley-kes-key $CARDANO_PRIVDIR/kes.skey --shelley-vrf-key $CARDANO_PRIVDIR/vrf.skey --shelley-operational-certificate $CARDANO_PRIVDIR/node.cert"
			# If we will be a failover/hot spare then keep the $CERTKEYARGS, but comment them out
			[ ".$FAILOVER_PARENT" != '.' ] && CERTKEYARGS="# $CERTKEYARGS"
		else
			# Go ahead and configure if key/cert is missing, but don't run the node with them
			[ "$KEYCOUNT" -ge 1 ] && debug "Not all needed keys/certs are present in $CARDANO_PRIVDIR; ignoring them (please generate!)"
		fi
	else
		# We assume if port is less than 6000 (usually 3000 or 3001), we're a relay-only node, not a block producer
		[ "$KEYCOUNT" -ge 3 ] && debug "Not running as block producer (no -P <pool> or port < 6000); ignoring key/cert files in $CARDANO_PRIVDIR"
	fi
	cat <<- _EOF > "$INSTALLDIR/cardano-node-starting-env.txt"
		PATH="/usr/local/bin:$INSTALLDIR:\$PATH"
		LD_LIBRARY_PATH="/usr/local/lib:$INSTALLDIR/lib:\$LD_LIBRARY_PATH"
		PKG_CONFIG_PATH="/usr/local/lib/pkgconfig:$INSTALLDIR/pkgconfig:\$PKG_CONFIG_PATH"
	_EOF
	chmod 0644 "$INSTALLDIR/cardano-node-starting-env.txt"
	[ -z "${IPV4_ADDRESS}" ] || IPV4ARG="--host-addr '$IPV4_ADDRESS'"
	[ -z "${IPV6_ADDRESS}" ] || IPV6ARG="--host-ipv6-addr '$IPV6_ADDRESS'"
	LIBSTARTUPSCRIPT=$(echo "$SYSTEMSTARTUPSCRIPT" | sed 's|^/lib/|/etc/|')
	[ -f "$LIBSTARTUPSCRIPT" ] && 'rm' -f "$LIBSTARTUPSCRIPT"  # Old startup script was here
	cat <<- _EOF > "$SYSTEMSTARTUPSCRIPT"
		# Make sure cardano-node is installed as a service
		[Unit]
		Description=Cardano Node start script
		After=multi-user.target
		
		[Service]
		User=$INSTALL_USER
		Environment=LD_LIBRARY_PATH=/usr/local/lib
		KillSignal=SIGINT
		RestartKillSignal=SIGINT
		StandardOutput=journal
		StandardError=journal
		SyslogIdentifier=cardano-node
		TimeoutStartSec=0
		TimeoutStopSec=3
		Type=simple
		KillMode=process
		WorkingDirectory=$INSTALLDIR
		ExecStart=$INSTALLDIR/cardano-node run --socket-path $INSTALLDIR/sockets/${BLOCKCHAINNETWORK}-node.socket --config $NODE_CONFIG_FILE $IPV4ARG $IPV6ARG --port $LISTENPORT --topology $CARDANO_FILEDIR/${BLOCKCHAINNETWORK}-topology.json --database-path ${CARDANO_DBDIR}/ $CERTKEYARGS
		Restart=on-failure
		RestartSec=10s
		LimitNOFILE=32768
		
		[Install]
		WantedBy=multi-user.target

	_EOF
	chown root.root "$SYSTEMSTARTUPSCRIPT"
	chmod 0644 "$SYSTEMSTARTUPSCRIPT"
fi
debug "Cardano node will be started (later): 
    $INSTALLDIR/cardano-node run \\
        --socket-path $INSTALLDIR/sockets/${BLOCKCHAINNETWORK}-node.socket \\
        --config $NODE_CONFIG_FILE \\
	$IPV4ARG $IPV6ARG --port $LISTENPORT \\
        --topology $CARDANO_FILEDIR/${BLOCKCHAINNETWORK}-topology.json \\
        --database-path ${CARDANO_DBDIR}/ \\
            $(echo "${CERTKEYARGS:-# No cert-key args available}" | sed 's/ --/\\\\\n            --/g' )"

# Modify topology file; add -R <node-ip:port> information
#
# If we're a relay, but no -R argument supplied, this is a bit odd
[ ".${NODE_INFO}" = '.' ] && [ ".$POOLNAME" != '.' ] \
	&& debug "Normally with a pool name specified (-P <pool>), we need -R <node-ip:port>; continuing anyway"

TOPOLOGY_FILE_WAS_EMPTY=''
if [[ ! -s "${CARDANO_FILEDIR}/${BLOCKCHAINNETWORK}-topology.json" ]]; then
	echo -e "{ \"Producers\": [ ] }\n" | jq | sponge "${CARDANO_FILEDIR}/${BLOCKCHAINNETWORK}-topology.json"
	TOPOLOGY_FILE_WAS_EMPTY='Y'
fi

# Add specified nodes to topology.json file (usually block producers), if any were specified on the command line
#
for NODE_INFO_PIECE in $(echo "$NODE_INFO" | sed 's/,/ /g'); do
	NODE_ADDRESS=$(echo "$NODE_INFO_PIECE" | sed 's/^\[*\([^]]*\)\]*:[^.:]*$/\1/') # Take out ip address part
	NODE_PORT=$(echo "$NODE_INFO_PIECE" | sed 's/^\[*[^]]*\]*:\([^.:]*\)$/\1/')    # Take out port part
	[ -z "${NODE_ADDRESS}" ] && [ -z "${NODE_PORT}" ] && err_exit 46 "$0: Node ip-address:port[,ip-address:port...] after -R is malformed; aborting"

	# Node block definition - set up as a literal JSON fragment
	BLOCKPRODUCERNODE="{ \"addr\": \"$NODE_ADDRESS\", \"port\": $NODE_PORT, \"valency\": 1 }"

	if [ ".$TOPOLOGY_FILE_WAS_EMPTY" = '.Y' ]; then
		# Topology file is empty; just create the whole thing all at once...
		if [[ ! -z "${NODE_ADDRESS}" ]]; then
			# ...if, that is, we have a node address (-R argment)
			jq ".Producers[]|=$BLOCKPRODUCERNODE" "${CARDANO_FILEDIR}/${BLOCKCHAINNETWORK}-topology.json" 2> /dev/null \
				| sponge "${CARDANO_FILEDIR}/${BLOCKCHAINNETWORK}-topology.json"
			TOPOLOGY_FILE_WAS_EMPTY=''
		fi
	else
		# If nodes were present in file already, add the node address to the topology file array
		if [ -z "${NODE_ADDRESS}" ]; then
			debug "No -R <node-ip:port>; if needed, hand edit: "${CARDANO_FILEDIR}/${BLOCKCHAINNETWORK}-topology.json""
		else
			ALREADY_PRESENT_IN_TOPOLOGY_FILE=''
			for keyAndVal in $(jq -r '.Producers[]|{addr,port}|to_entries[]|(.key+"="+(.value | tostring))' "${CARDANO_FILEDIR}/${BLOCKCHAINNETWORK}-topology.json" 2> /dev/null | xargs | tr ' ' ','); do
				if [ ".$keyAndVal" = ".addr=${NODE_ADDRESS},port=${NODE_PORT}" ]; then
					ALREADY_PRESENT_IN_TOPOLOGY_FILE='Y'
					break
				fi
			done
			if [ -z "$ALREADY_PRESENT_IN_TOPOLOGY_FILE" ]; then
				PRODUCER_COUNT=$(jq '.Producers|length' "${CARDANO_FILEDIR}/${BLOCKCHAINNETWORK}-topology.json" 2> /dev/null)
				debug "Adding ${NODE_ADDRESS}::${NODE_PORT} producer #${PRODUCER_COUNT} in: ${CARDANO_FILEDIR}/${BLOCKCHAINNETWORK}-topology.json"
				jq ".Producers[${PRODUCER_COUNT}]|=$BLOCKPRODUCERNODE" "${CARDANO_FILEDIR}/${BLOCKCHAINNETWORK}-topology.json" 2> /dev/null \
					| sponge "${CARDANO_FILEDIR}/${BLOCKCHAINNETWORK}-topology.json"
			else
				debug "Topology file already has a Producers element for [${NODE_ADDRESS}]:${NODE_PORT}; no need to add"
			fi
		fi
	fi
done

# Remove IOHK entry from topology.json file if we're a block producer
#
SUBSCRIPT=''
COUNTER=0
for PRODUCERADDR in $(jq '.Producers[]|.addr' "${CARDANO_FILEDIR}/${BLOCKCHAINNETWORK}-topology.json" 2> /dev/null); do
	COUNTER=$(expr $COUNTER + 1)
	if echo "$PRODUCERADDR" | egrep -q '(iohk|emurgo)\.'; then
		SUBSCRIPT=$(expr $COUNTER - 1)
		break
	fi
done
# If we are a block producer (port 6000 or higher and a pool name - assumed to be a producer node)
if [ "$LISTENPORT" -ge 6000 ] && [ ".$POOLNAME" != '.' ]; then
	if [[ ! -z "$SUBSCRIPT" ]]; then
		# We're a block producer; deleting Producers[${SUBSCRIPT}] from ${CARDANO_FILEDIR}/${BLOCKCHAINNETWORK}-topology.json
		debug "We're a block producer; deleting IOKH entry from: ${CARDANO_FILEDIR}/${BLOCKCHAINNETWORK}-topology.json"
		jq "del(.Producers[${SUBSCRIPT}])" "${CARDANO_FILEDIR}/${BLOCKCHAINNETWORK}-topology.json" \
			| sponge "${CARDANO_FILEDIR}/${BLOCKCHAINNETWORK}-topology.json"
	fi
else
	if [[ ! -z "$SUBSCRIPT" ]]; then
		debug "We're a relay; setting valency of IOHK relay (entry #$SUBSCRIPT) to 8; will leave others alone"
		jq ".Producers[${SUBSCRIPT}].valency|=8" "${CARDANO_FILEDIR}/${BLOCKCHAINNETWORK}-topology.json" \
			| sponge "${CARDANO_FILEDIR}/${BLOCKCHAINNETWORK}-topology.json"
	fi
fi

[ -s "${CARDANO_FILEDIR}/${BLOCKCHAINNETWORK}-topology.json" ] \
	|| err_exit 146 "$0: Empty topology file; fix by hand: ${CARDANO_FILEDIR}/${BLOCKCHAINNETWORK}-topology.json; aborting"

# Pull SPOS scripts and related utilities like bech32 and vit-kedqr
#
cd "$BUILDDIR"
if ischroot; then
	debug "In a chroot, so skipping bech32, b2sum, and vit-kedqr install; rerun on boot from backup"
else
	if download_github_code "$BUILDDIR" "$INSTALLDIR" "${IOHKREPO}/bech32" "$SKIP_RECOMPILE" "$BUILDLOG" '' '1.1.0' 'bech32'; then
		cabal_install_software "$BUILDDIR" "$INSTALLDIR" 'bech32' "$CABAL" "$BUILDLOG" '' '' "$BLOCKCHAINNETWORK"
	fi
	go get bitbucket.org/dchest/b2sum 1>> "$BUILDLOG" 2>&1
	if download_github_code "$BUILDDIR" "$INSTALLDIR" "${IOHKREPO}/vit-kedqr" "$SKIP_RECOMPILE" "$BUILDLOG" '' '1.1.0'; then
		cd "$BUILDDIR/vit-kedqr"
		debug "Compiling and installing vit-kedqr to $INSTALLDIR; on first pass takes a long time"
		if cargo build --bin vit-kedqr	1>> "$BUILDLOG" 2>&1; then
			cargo install --path . --force --locked	1>> "$BUILDLOG" 2>&1
			cp -f $(find "$BUILDDIR/vit-kedqr" -type f -name vit-kedqr ! -path '*OLD*') "$INSTALLDIR/vit-kedqr" 1>> "$BUILDLOG" 2>&1
		else
			debug "Failed to 'cargo build' vit-kedqr; continuing anyway"
		fi
	fi
fi

if download_github_code "$BUILDDIR" "$INSTALLDIR" "${IOHKREPO}/cardano-addresses" "$SKIP_RECOMPILE" "$BUILDLOG" '' '' 'cardano-address' 'Y'; then
	cabal_install_software "$BUILDDIR" "$INSTALLDIR" 'cardano-addresses' "$CABAL" "$BUILDLOG" 'cardano-address' "$GHCVERSION"
fi

cd "$BUILDDIR"
if [ ".$DONT_OVERWRITE" != '.Y' ]; then
	if download_github_code "$BUILDDIR" "$INSTALLDIR" "$SPOSREPO" "$SKIP_RECOMPILE" "$BUILDLOG" "$CARDANO_SPOSDIR" '' 'placeholder-for-all-SPOS-scripts'; then
		debug "Installing SPOS scripts to ${CARDANO_SPOSDIR} (only use these if you're a pro)"
		cd "./scripts/cardano/${BLOCKCHAINNETWORK}"
		cp -f ./* "${CARDANO_SPOSDIR}/"
		sed -i "${CARDANO_SPOSDIR}/00_common.sh" \
			-e "s|^\#* *socket=['\"][^'\"]*['\"]|socket=\"${INSTALLDIR}/sockets/${BLOCKCHAINNETWORK}-node.socket\"|g" \
			-e "s|^\#* *genesisfile=['\"][^'\"]*['\"]|genesisfile=\"${CARDANO_FILEDIR}/${BLOCKCHAINNETWORK}-shelley-genesis.json\"|g" \
			-e "s|^\#* *cardanocli=['\"][^'\"]*['\"]|cardanocli=\"${INSTALLDIR}/cardano-cli\"|g" \
			-e "s|^\#* *cardanonode=['\"][^'\"]*['\"]|cardanonode=\"${INSTALLDIR}/cardano-node\"|g" \
			-e "s|^\#* *bech32_bin=['\"][^'\"]*['\"]|bech32_bin=\"${INSTALLDIR}/bech32\"|g" \
			-e "s|^\#* *offlineMode=['\"][^'\"]*['\"]|offlineMode=\"yes\"|g" \
			-e "s|^\#* *offlineFile=['\"][^'\"]*['\"]|offlineFile=\"${CARDANO_SPOSDIR}/offlineTransfer.json\"|g" \
			-e "s|^\#* *jcli_bin=['\"][^'\"]*['\"]|jcli_bin=\"${INSTALLDIR}/jcli\"|g" \
			-e "s|^\#* *vitkedqr_bin=['\"][^'\"]*['\"]|vitkedqr_bin=\"${INSTALLDIR}/vit-kedqr\"|g" \
			-e "s|^\#* *cardanohwcli=['\"][^'\"]*['\"]|cardanohwcli=\"${INSTALLDIR}/cardano-hw-cli\"|g" \
			-e "s|^\#* *cardanometa=['\"][^'\"]*['\"]|cardanometa=\"${INSTALLDIR}/token-metadata-creator-not-installed\"|g" \
			-e "s|^\#* *queryTokenRegistry=['\"][^'\"]*['\"]|queryTokenRegistry=\"no\"|g" \
				|| err_exit 110 "$0: Failed to modify SPOS common file, ${CARDANO_SPOSDIR}/00_common.sh; aborting"	
	fi
fi

# UPDATE gLiveView.sh and other guild scripts 
#
cd "$INSTALLDIR"
if [ ".$DONT_OVERWRITE" != '.Y' ]; then
	debug "Downloading guild scripts (incl. gLiveView.sh) to: ${CARDANO_SCRIPTDIR}"
	if download_github_code "$BUILDDIR" "$INSTALLDIR" "$GUILDREPO" "$SKIP_RECOMPILE" "$BUILDLOG" "$CARDANO_SCRIPTDIR" '' 'placeholder-for-Guild-scripts'; then
		pushd "$BUILDDIR/guild-operators"	1>> "$BUILDLOG" 2>&1
		[ -z "$GUILDREPOBRANCH" 	]	|| git switch "$GUILDREPOBRANCH"		1>> "$BUILDLOG" 2>&1
		[ -z "$GUILDSCRIPT_VERSION"	]	|| git checkout "$GUILDSCRIPT_VERSION"	1>> "$BUILDLOG" 2>&1 \
			|| debug "$0: Failed to checkout CNTool version $GUILDSCRIPT_VERSION; using default"
		git fetch 1>> "$BUILDLOG" 2>&1
		cd './scripts/cnode-helper-scripts'
		cp -f ./* "${CARDANO_SCRIPTDIR}/"
		popd 1>> "$BUILDLOG" 2>&1
	fi
	debug "Resetting variables in Guild env file; e.g., NODE_CONFIG_FILE -> $NODE_CONFIG_FILE"
	sed -i "${CARDANO_SCRIPTDIR}/env" \
		-e "s@^\#* *CCLI=['\"][^'\"]*['\"]@CCLI=\"$INSTALLDIR/cardano-cli\"@g" \
		-e "s@^\#* *CNCLI=['\"][^'\"]*['\"]@CNCLI=\"$INSTALLDIR/cncli\"@g" \
		-e "s|^\#* *CONFIG=\"\${CNODE_HOME}/[^/]*/[^/.]*\.json\"|CONFIG=\"$NODE_CONFIG_FILE\"|g" \
		-e "s|^\#* *UPDATE_CHECK=['\"][^'\"]*['\"]|UPDATE_CHECK=\"N\"|g" \
		-e "s|^\#* *SOCKET=\"\${CNODE_HOME}/[^/]*/[^/.]*\.socket\"|SOCKET=\"$INSTALLDIR/sockets/${BLOCKCHAINNETWORK}-node.socket\"|g" \
		-e "s|^\#* *CNODE_HOME=[^#]*|CNODE_HOME=\"$INSTALLDIR\" |g" \
		-e "s|^\#* *CNODE_PORT=[^#]*|CNODE_PORT=\"$LISTENPORT\" |g" \
		-e "s|^\#* *TOPOLOGY=[^#]*|TOPOLOGY=\"$CARDANO_FILEDIR/${BLOCKCHAINNETWORK}-topology.json\" |g" \
		-e "s|^\#* *LOG_DIR=[^#]*|LOG_DIR=\"${INSTALLDIR}/logs\" |g" \
		-e "s|^\#* *DB_DIR=[^#]*|DB_DIR=\"$CARDANO_DBDIR\" |g" \
		-e "s|^\#* *WALLET_FOLDER=[^#]*|WALLET_FOLDER=\"${CARDANO_PRIVDIR}/wallet\" |g" \
		-e "s|^\#* *POOL_FOLDER=[^#]*|POOL_FOLDER=\"${CARDANO_PRIVDIR}/pool\" |g" \
		-e "s|^\#* *ASSET_FOLDER=[^#]*|ASSET_FOLDER=\"${CARDANO_PRIVDIR}/asset\" |g" \
			|| err_exit 109 "$0: Failed to modify Guild 'env' file, ${CARDANO_SCRIPTDIR}/env; aborting"	

	# Let other Guild scripts know that our cardano-node service is 'cardano-node' (not cnode)
	sed -i "${CARDANO_SCRIPTDIR}/env" -e '1 s@^\(#!.*$\)@\1\n#cardano-node_HOME=@;1 n;'

	if [ ".$POOLNAME" != '.' ]; then
		sed -i "${CARDANO_SCRIPTDIR}/env" \
			-e "s@^\#* *POOL_NAME=['\"]*[0-9]*['\"]*@POOL_NAME=\"$POOLNAME\"@g" 
	fi
	if [ ".${EXTERNAL_HOSTNAME}" != '.' ] && [ "$LISTENPORT" -lt 6000 ] && [ ".$NODE_INFO" != '.' ]; then   # Assume relay if port < 6000 
		NODE_LIST=$(echo "$NODE_INFO" | sed 's/,/|/g')
		debug "Adding hostname ($EXTERNAL_HOSTNAME) and custom peers (${NODE_LIST:-none provided [-R <relays>])}) to topologyUpdater.sh file"
		sed -i "${CARDANO_SCRIPTDIR}/topologyUpdater.sh" \
			-e "s@^\#* *CNODE_HOSTNAME=\"[^#]*@CNODE_HOSTNAME=\"$EXTERNAL_HOSTNAME\" @g" \
			-e "s@^\#* *CUSTOM_PEERS=\"[^#]*@CUSTOM_PEERS=\"$NODE_LIST\" @g" \
			-e "s@^\#* *MAX_PEERS=['\"]*[0-9][0-9]*['\"]* @MAX_PEERS=11 @g" \
				|| err_exit 109 "$0: Failed to modify Guild 'topologyUpdater.sh' file, ${CARDANO_SCRIPTDIR}/topologyUpdater.sh; aborting"
		if [ ".$POOLNAME" != '.' ]; then 
			# We are a relay node; point cncli.sh Guild script at BP node (and standby)
			FIRSTNODE=$(echo "$NODE_INFO" | awk -F',' '{ print $1 }')	# Would like to have a way to do multiple relays
			if [ ".$FIRSTNODE" != '.' ]; then							# ...but cncli topology.json file can take only one 'host'
				for SCRIPTNAME in 'env' 'cncli.sh'; do
					sed -i "${CARDANO_SCRIPTDIR}/$SCRIPTNAME" \
						-e "s@^\#* *PT_HOST=['\"][^'\"]*['\"]@PT_HOST=\"$FIRSTNODE\"@g" 
				done
			fi
		fi
	else
		debug "Not modifying topologyUpdater.sh script; assuming block producer (listen port, $LISTENPORT >= 6000)"
	fi

	debug "Rewriting Guild deploy-as-systemd.sh to ignore cnode.sh and use our system startup script"
	(echo -e '#!'"/usr/bin/env bash\nvname='cardano-node'\nPARENT=\"\$(dirname \"\$0\")\"\n. \"\${PARENT}\"/env offline\n"; \
		sed '1,/^EOF"/d' < "${CARDANO_SCRIPTDIR}/deploy-as-systemd.sh") \
	 		| sponge "${CARDANO_SCRIPTDIR}/deploy-as-systemd.sh"
	[ $(find /etc/systemd -type f -name 'cnode-*' -exec egrep -q ardano {} \; -print 2> /dev/null | wc -l) -gt 0 ] \
		&& debug "CNTool scripts found in /etc/systemd; disable/remove if needed: find /etc/systemd -type f -name 'cnode-*' ..."
fi
[ -x "${CARDANO_SCRIPTDIR}/gLiveView.sh" ] \
    || err_exit 108 "$0: Can't find executable ${CARDANO_SCRIPTDIR}/gLiveView.sh; Guild scripts missing; aborting (drop -d option?)"

# Re-lay-out directories so that CNode Tools work
debug "Adding symlinks for socket, and for db and priv dirs, to make CNode Tools work"
[ -L "$INSTALLDIR/sockets/node0.socket" ] && rm -f "$INSTALLDIR/sockets/node0.socket"
[ -L "$INSTALLDIR/sockets/node0.socket" ] \
	|| (ln -sf "$INSTALLDIR/sockets/${BLOCKCHAINNETWORK}-node.socket" "$INSTALLDIR/sockets/node0.socket" 1>> "$BUILDLOG" 2>&1 \
		|| debug "Note: Failed to: 'ln -sf $INSTALLDIR/sockets/${BLOCKCHAINNETWORK}-node.socket $INSTALLDIR/sockets/node0.socket'")
[ -L "$INSTALLDIR/db" ] && rm -f "$INSTALLDIR/db"
[ -L "$INSTALLDIR/db" ] \
	|| (ln -sf "$CARDANO_DBDIR"	"$INSTALLDIR/db" 1>> "$BUILDLOG" 2>&1 \
		|| debug "Note: Failed to: 'ln -sf $CARDANO_DBDIR $INSTALLDIR/db'")
[ -d "$INSTALLDIR/priv" ] && [ $(ls -A "$INSTALLDIR/priv" 2> /dev/null | wc -l) -eq 0 ] && rm "$INSTALLDIR/priv"
[ -L "$INSTALLDIR/priv" ] && rm "$INSTALLDIR/priv"
[ -L "$INSTALLDIR/priv" ] \
	|| (ln -sf "$CARDANO_PRIVDIR" "$INSTALLDIR/priv" 1>> "$BUILDLOG" 2>&1 \
		|| debug "Note: Failed to: 'ln -sf $CARDANO_PRIVDIR $INSTALLDIR/priv'")
[ -L "$OPTCARDANO_DIR/cnode" ] && rm -f "$OPTCARDANO_DIR/cnode"
[ -L "$OPTCARDANO_DIR/cnode" ] \
	|| (ln -sf "$INSTALLDIR" "$OPTCARDANO_DIR/cnode" \
		|| debug "Note: Failed to: 'ln -sf $INSTALLDIR $OPTCARDANO_DIR/cnode'")
[ -L "$INSTALLDIR/monitoring" ] && rm -f "$INSTALLDIR/monitoring"
[ -L "$INSTALLDIR/monitoring" ] \
	|| (ln -sf "$OPTCARDANO_DIR/cnode" "$INSTALLDIR/monitoring" \
		|| debug "Note: Failed to: 'ln -sf $OPTCARDANO_DIR/cnode $INSTALLDIR/monitoring'")

# build and install other utilities - python, rust-based
#
cd "$BUILDDIR"
if download_github_code "$BUILDDIR" "$INSTALLDIR" 'https://github.com/AndrewWestberg/cncli' "$SKIP_RECOMPILE" "$BUILDLOG"; then
	debug "Updating Rust in prep for cncli install"
	cd './cncli'
	[ -d "$HOME/.cargo/bin" ] || mkdir -p "$HOME/.cargo/bin"; chown -R $USER "$HOME/.cargo"
	rustup install stable	1>> "$BUILDLOG" 2>&1
	rustup default stable	1>> "$BUILDLOG" 2>&1
	rustup update			1>> "$BUILDLOG" 2>&1 || debug "Rust update failed, but moving on anyway"
	rustup component add clippy rustfmt				1>> "$BUILDLOG" 2>&1
	cargo +stable install --path . --force --locked 1>> "$BUILDLOG" 2>&1 \
		|| debug "Build of cncli ('cargo install') failed, but moving on (details in $BUILDLOG)"
	[ -x './bin/cncli' ] && cp -f './bin/cncli' "$INSTALLDIR" 
	[ -x './target/release/cncli' ] && cp -f './target/release/cncli' "$INSTALLDIR" 

	debug "Installing python-cardano and cardano-tools using $PIP"
	$PIP install --upgrade pip   1>> "$BUILDLOG" 2>&1
	$PIP install pip-tools       1>> "$BUILDLOG" 2>&1
	$PIP install python-cardano  1>> "$BUILDLOG" 2>&1
	$PIP install cardano-tools   1>> "$BUILDLOG" 2>&1 \
		|| err_exit 117 "$0: Unable to install cardano tools: '$PIP install cardano-tools'; aborting"
fi

# Ensuring again that the cardano user itself can modify its topology file; ditto for Guild env and topologyUpdater files (note last arg is doubled)
create_and_secure_installdir "$BLOCKCHAINNETWORK" "$INSTALLDIR" "$CARDANO_FILEDIR" "$CARDANO_DBDIR" "$CARDANO_PRIVDIR" "$CARDANO_SCRIPTDIR" "$CARDANO_SPOSDIR" "$INSTALL_USER" "$INSTALL_USER" 'root'

# Re-enable cardano-node and ensure auto-starts
#
debug "Setting up cardano-node as system service"
systemctl daemon-reload		1>> "$BUILDLOG" 2>&1
if [ ".$START_SERVICES" != '.N' ]; then
	systemctl enable cardano-node		1>> "$BUILDLOG" 2>&1  # Unlike other services, don't enable cardano-node unless asked (no -N)
	systemctl start cardano-node		1>> "$BUILDLOG" 2>&1; sleep 3
	systemctl is-active cardano-node	1> /dev/null \
		|| err_exit 138 "$0: Problem enabling (or starting) cardano-node service; aborting (run 'systemctl status cardano-node')"
fi

#############################################################################
#
debug "Tasks:"
debug "    You *may* have to clear ${CARDANO_DBDIR} before cardano-node can rerun (try and see)"
debug "    If not done already, create a user that can sudo and set up key-based SSH access to that account"
debug "    Then lock the root account and turn off non-key SSH access in /etc/ssh/sshd_config"
debug "    Check network/firewall config (run 'ip addr', 'ufw status numbered'; also 'tail -f /var/log/ufw.log')"
debug "    Follow syslogged activity by running: 'journalctl --unit=cardano-node --follow'"
debug "    Monitor node activity by running: 'cd $CARDANO_SCRIPTDIR; bash ./gLiveView.sh'"
debug "    Please ensure no /home directory is world-readable (many distros make world-readable homes)"
debug "    Please examine topology file; run: 'less \"${CARDANO_FILEDIR}/${BLOCKCHAINNETWORK}-topology.json\"'"
debug "    Install ddclient, if needed; edit /etc/ddclient.conf then restart: systemctl restart ddclient"
debug "    Have your router or firewall port forward to tcp 9090 if you're using hosted Grafana (-H)"
if date +"%Z %z" | egrep -q UTC; then
	timedatectl set-timezone "$(curl --fail https://ipapi.co/timezone 2> /dev/null)" 1>> "$BUILDLOG" 2>&1 \
	    || debug "    Please also set the timezone (e.g., 'timedatectl set-timezone \"America/Chicago\"')"
fi

if [ ".$SETUP_DBSYNC" = '.Y' ]; then
	# SCRIPT_PATH was set earlier on (beginning of this script)
	if [ -e "$SCRIPT_PATH/pi-cardano-dbsync-setup.sh" ]; then
		# Run the dbsync script if we managed to find it
		debug "Running dbsync setup script: '$SCRIPT_PATH/pi-cardano-dbsync-setup.sh'"
		. "$SCRIPT_PATH/pi-cardano-dbsync-setup.sh" \
			|| err_exit 47 "$0: Can't execute '$SCRIPT_PATH/pi-cardano-dbsync-setup.sh'"
	else
		debug "Skipping dbsync setup (can't find dbsync setup script, ${SCRIPT_PATH:-.}/pi-cardano-dbsync-setup.sh)"
	fi
fi

sed -i 's/ # (not completed)/ # (completed)/' "$LASTRUNFILE" 
rm -f "$TEMPLOCKFILE" 2> /dev/null
rm -f "$TMPFILE"      2> /dev/null
rm -f "$LOGFILE"      2> /dev/null
