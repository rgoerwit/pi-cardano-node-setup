#!/bin/bash
#
#############################################################################
#
#  Copyright 2021 Richard L. Goerwitz III
#
#    This code may be freely used for commercial or noncommercial purposes.
#    I make no guarantee, however, about this code's correctness or fitness
#    for any particular purpose.  Use it at your own risk.  For full licensing
#    information, see: https://github.com/rgoerwit/pi-cardano-node-setup/
#
#############################################################################
#
#  Builds cardano-node and friends on a Raspberry Pi running
#  Ubuntu LTS.
#
#############################################################################
#

err_exit() {
  EXITCODE=$1; shift
  (printf "$*" && echo -e "") 1>&2; 
  # pushd -0 >/dev/null && dirs -c
  exit $EXITCODE 
}

# Read in trapping and locking code, if present
SCRIPT_PATH=$(readlink -e -- "$0" | sed 's:/[^/]*$::' | tr -d '\r\n')
if [ ".$SCRIPT_PATH" != '.' ] && [ -e "$SCRIPT_PATH/pi-cardano-node-fake-code.sh" ]; then
	. "$SCRIPT_PATH/pi-cardano-node-fake-code.sh" \
		|| err_exit 47 "$0: Can't execute $SCRIPT_PATH/pi-cardano-node-fake-code.sh"
fi

usage() {
  cat << _EOF 1>&2

Usage: $PROGNAME [-4 <external IPV4>] [-6 <external IPV6>] [-b <builduser>] [-c <node config filename>] [-d] [-D] \
    [-G <GCC-arch] [-h <SID:password>] [-m <seconds>] [-n <mainnet|testnet|launchpad|guild|staging>] [-o <overclock speed>] \
	[-p <port>] [-r]  [-R <relay-ip:port>] [-s <subnet>] [-S] [-u <installuser>] [-w <libsodium-version-number>] \
	[-v <VLAN num> ] [-x]

Sets up a Cardano relay node on a new Pi 4 running Ubuntu LTS distro

Examples:

New (overclocking) mainnet setup on TCP port 3000:   $PROGNAME -D -b builduser -u cardano -n mainnet -o 2100 -p 3000  
Refresh of existing mainnet setup (keep existing config files):  $PROGNAME -D -d -b builduser -u cardano -n mainnet

-4    External IPv4 address (defaults to 0.0.0.0)
-6    External IPv6 address (defaults to NULL)
-b    User whose home directory will be used for compiling (defaults to 'builduser')
-c    Node configuration file (defaults to <install user home dir>/<network>-config.json)
-d    Don't overwrite config files, or 'env' file for gLiveView
-D    Emit chatty debugging output about what the program is doing
-g    GHC operating system (defaults to deb10; could also be deb9, centos7, etc.)
-G    GHC gcc architecture (default is -march=Armv8-A); the value here is in the form of a flag supplied to GCC
-h    Install (naturally, hidden) WiFi; format: SID:password (only use WiFi on the relay, not block producer)
-m    Maximum time in seconds that you allow the file download operation to take before aborting (Default: 80s)
-n    Connect to specified network instead of mainnet network (Default: mainnet)
      e.g.: -n testnet (alternatives: allegra launchpad mainnet mary_qa shelley_qa staging testnet...)
-o    Overclocking value (should be something like, e.g., 2100 for a Pi 4)
-p    Listen port (default 3000); assumes we are a block producer if <port> is >= 6000
-r    Install RDP
-R    Relay information (ip-address:port, separated by a colon) to add to topology.json file (clobbers other entries if listen -p <port> is >= 6000)
-s    Networks to allow SSH from (comma-separated, CIDR)
-S    Skip firewall configuration
-u    User who will run the executables and in whose home directory the executables will be installed
-w    Specify a libsodium version (defaults to the wacky version the Cardano project recommends)
-v    Enable vlan <number> on eth0; DHCP to that VLAN; disable eth0 interface
-x    Don't recompile anything big, like ghc, libsodium, and cardano-node
_EOF
  exit 1
}

while getopts 4:6:b:c:dDg:G:h:m:n:o:p:rR:s:Su:v:w:x opt; do
  case "${opt}" in
    '4' ) IPV4_ADDRESS="${OPTARG}" ;;
    '6' ) IPV6_ADDRESS="${OPTARG}" ;;
	b ) BUILD_USER="${OPTARG}" ;;
	c ) NODE_CONFIG_FILE="${OPTARG}" ;;
	d ) DONT_OVERWRITE='Y' ;;
	D ) DEBUG='Y' ;;
	g ) GHCOS="${OPTARG}" ;;
	G ) GHC_GCC_ARCH="${OPTARG}" ;;
    h ) HIDDEN_WIFI_INFO="${OPTARG}" ;;
    m ) WGET_TIMEOUT="${OPTARG}" ;;
    n ) BLOCKCHAINNETWORK="${OPTARG}" ;;
	o ) OVERCLOCK_SPEED="${OPTARG}" ;;
    p ) LISTENPORT="${OPTARG}" ;;
    r ) INSTALLRDP='Y' ;;
	R ) RELAY_INFO="${OPTARG}" ;; 
	s ) MY_SUBNETS="${OPTARG}" ;;
	S ) SKIP_FIREWALL_CONFIG='Y' ;;
    u ) INSTALL_USER="${OPTARG}" ;;
	v ) VLAN_NUMBER="${OPTARG}" ;;
    w ) LIBSODIUM_VERSION="${OPTARG}" ;;
    x ) SKIP_RECOMPILE='Y' ;;
    \? ) usage ;;
    esac
done

APTINSTALLER="apt-get -q --assume-yes"  # could also be "apt --assume-yes" or for other distros, "yum -y"
$APTINSTALLER install dnsutils 1> /dev/null
[ -z "${IPV4_ADDRESS}" ] && IPV4_ADDRESS='0.0.0.0' 2> /dev/null
[ -z "${EXTERNAL_IPV4_ADDRESS}" ] && EXTERNAL_IPV4_ADDRESS="$(dig +timeout=30 +short myip.opendns.com @resolver1.opendns.com)" 2> /dev/null
[ -z "${EXTERNAL_IPV6_ADDRESS}" ] && EXTERNAL_IPV6_ADDRESS="$(dig +timeout=10 +short -6 myip.opendns.com aaaa @resolver1.ipv6-sandbox.opendns.com 1> /dev/null)" 2> /dev/null
[ -z "${MY_SUBNET}" ] && MY_SUBNET=$(ifconfig | awk '/netmask/ { split($4,a,":"); print $2 "/" a[1] }' | tail -1)  # With a Pi, you get just one RJ45 jack
[ -z "${MY_SUBNET}" ] && MY_SUBNET=$(ifconfig | awk '/inet6/ { split($4,a,":"); print $2 "/" a[1] }' | tail -1)
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
INSTALLDIR="/home/${INSTALL_USER}"
BUILDDIR="/home/${BUILD_USER}/Cardano-BuildDir"
BUILDLOG="$BUILDDIR/build-log-$(date '+%Y-%m-%d-%H:%M:%S').log"
CARDANO_DBDIR="${INSTALLDIR}/db-${BLOCKCHAINNETWORK}"
CARDANO_FILEDIR="${INSTALLDIR}/files"
CARDANO_SCRIPTDIR="${INSTALLDIR}/scripts"

# Sends output to console as well as the $BUILDLOG file
debug() {
	[ -z "$DEBUG" ] || echo -e "$@" | tee -a "$BUILDLOG" 
} 

skip_op() {	
	debug 'Skipping: ' "$@" 
}

[ -z "${NODE_CONFIG_FILE}" ] && NODE_CONFIG_FILE="$CARDANO_FILEDIR/${BLOCKCHAINNETWORK}-config.json"
[ "${SUDO}" = 'Y' ] && sudo="sudo" || sudo=""
EXTRACABALARGS=''
if [ "${SUDO}" = 'Y' ] && [ $(id -u) -eq 0 ]; then
	debug "Running script as root (sadly, yes, this is needed)"
else
	err_exit 12 "$0: Script must be run as root (eliminates confusion over real vs effective user); aborting"
fi

debug "To get the latest version: 'git clone https://github.com/rgoerwit/pi-cardano-node-setup/' (refresh with 'git pull')"
debug "INSTALLDIR is '/home/${INSTALL_USER}'"
debug "BUILDDIR is '/home/${BUILD_USER}/Cardano-BuildDir'"
debug "CARDANO_FILEDIR is '${INSTALLDIR}/files'"
debug "NODE_CONFIG_FILE is '${NODE_CONFIG_FILE}'"

# -h argument supplied - parse WiFi info (WiFi usually not recommended, but OK esp. for relay, in a pinch)
if [ ".${HIDDEN_WIFI_INFO}" != '.' ]; then
	HIDDENWIFI=$(echo "$HIDDEN_WIFI_INFO" | awk -F: '{ print $1 }')
	HIDDENWIFIPASSWORD=$(echo "$HIDDEN_WIFI_INFO" | awk -F: '{ print $2 }')
	[ -z "${HIDDENWIFI}" ] && [ -z "${HIDDENWIFIPASSWORD}" ] && err_exit 45 "$0: Please supply a WPA WiFi NetworkID:Password (or omit the -h argument for no WiFi)"
fi

# -R argument supplied - this is a block-producing node; parse relay info
if [ ".${RELAY_INFO}" != '.' ]; then
	RELAY_ADDRESS=$(echo "$RELAY_INFO" | awk -F: '{ print $1 }')
	RELAY_PORT=$(echo "$RELAY_INFO" | awk -F: '{ print $2 }')
	[ -z "${RELAY_ADDRESS}" ] && [ -z "${RELAY_PORT}" ] && err_exit 46 "$0: You didn't supply a relay ip-address:port after -R; aborting"
fi

GUILDREPO="https://github.com/cardano-community/guild-operators"
GUILDREPO_RAW="https://raw.githubusercontent.com/cardano-community/guild-operators"
GUILDREPO_RAW_URL="${GUILDREPO_RAW}/master"
WPA_SUPPLICANT="/etc/wpa_supplicant/wpa_supplicant.conf"
WGET="wget --quiet --retry-connrefused --waitretry=10 --read-timeout=20 --timeout $WGET_TIMEOUT -t 5"
GHCVERSION="8.10.4"
GHCARCHITECTURE="$(arch)"         # could potentially be aarch64, arm7, arm8, etc. for example; see http://downloads.haskell.org/~ghc/
GCCMARMARG=""                     # will be -marm for Raspberry Pi OS 32 bit; blank for Ubuntu 64
if [ -z "$GHC_GCC_ARCH" ]; then
	(echo "$(arch)" | egrep -q 'arm|aarch') \
		&& GHC_GCC_ARCH="-march=Armv8-A"  # will be -march=armv7-a for Raspberry Pi OS 32 bit; -march=Armv8-A for Ubuntu 64
fi
[ -z "$GHCOS" ] && GHCOS="deb10"  # could potentially be deb9, etc, for example; see http://downloads.haskell.org/~ghc/
CABAL="$INSTALLDIR/cabal"
MAKE='make'
CARDANONODEVERSION="1.25.1"
PIVERSION=$(cat /proc/cpuinfo | egrep '^Model' | sed 's/^Model\s*:\s*//i')
PIP="pip$(apt-cache pkgnames | egrep '^python[2-9]*$' | sort | tail -1 | tail -c 2 |  tr -d '[:space:]')"; 
if [ ".$SKIP_RECOMPILE" = '.Y' ]; then
    MAKE='skip_op'
    CABAL='skip_op'
fi 

# Guess which cabal binaries to use
#
CABAL_VERSION='3.2.0.0'
if echo "$(arch)" | egrep -q 'arm|aarch'; then
    CABAL_VERSION='3.4.0.0-rc4'
	[ -z "$CABALDOWNLOADPREFIX" ] && CABALDOWNLOADPREFIX="http://home.smart-cactus.org/~ben/ghc/cabal-install-${CABAL_VERSION}"
	[ -z "$CABALARCHITECTURE" ] && CABALARCHITECTURE="$(arch)" # raspberry pi OS 32-bit is armv7l; ubuntu 64 is aarch64 See http://home.smart-cactus.org/~ben/ghc/
	[ -z "$CABAL_OS" ] && CABAL_OS='linux' # Could be deb10 as well, if available?
else
	[ -z "$CABALDOWNLOADPREFIX" ] && CABALDOWNLOADPREFIX="https://downloads.haskell.org/~cabal/cabal-install-${CABAL_VERSION}/cabal-install-${CABAL_VERSION}"
	[ -z "$CABALARCHITECTURE" ] && CABALARCHITECTURE='x86_64'
	[ -z "$CABAL_OS" ] && CABAL_OS='unknown-linux'
fi

# Change default startup user to match OS; usually oldest home is the user we want
PIUSER=$(ls -c /home | head -1 | tr '[:upper:]' '[:lower:]')
# Use ubuntu for ubuntu, pi for Raspberry Pi OS
if egrep -iq Ubuntu "/etc/issue"; then
    export PIUSER="ubuntu"
fi

# Make sure our build user exists and belongs to all the good groups
#
debug "Checking and (if need be) making build user: ${BUILD_USER}"
if id "$BUILD_USER" 1>> /dev/null; then
    : do nothing because user exists
else
    # If we have to create the build user, lock the password
    useradd -m -s /bin/bash "$BUILD_USER"   1>> /dev/null
    passwd -l "$BUILD_USER"                 1>> /dev/null
fi
for grp in $(groups $PIUSER); do
    if [ ".$grp" != '.' ] && [ ".$grp" != '.:' ] && [ ".$grp" != ".$PIUSER" ]; then
		usermod -a -G "$grp" "$BUILD_USER"  1>> /dev/null
    fi
done
#
mkdir "$BUILDDIR" 2> /dev/null
chown "${BUILD_USER}.${BUILD_USER}" "$BUILDDIR"
chmod 2755 "$BUILDDIR"
touch "$BUILDLOG"

[ ".$SKIP_RECOMPILE" = '.Y' ] || debug "You are compiling (NO -x flag supplied); this will take several hours now...."
debug "To monitor progress, run this in another window: tail -f \"$BUILDLOG\""

# Update system, install prerequisites, utilities, etc.
#
debug "Updating system, eeprom; ensuring necessary prerequisites are installed"
$APTINSTALLER update        1>> "$BUILDLOG"
$APTINSTALLER upgrade       1>> "$BUILDLOG"
$APTINSTALLER dist-upgrade  1>> "$BUILDLOG"
# Install a bunch of necessary development and support packages
$APTINSTALLER install aptitude autoconf automake bc bsdmainutils build-essential curl dialog emacs g++ git git gnupg \
	gparted htop iproute2 jq libffi-dev libgmp-dev libncursesw5 libpq-dev libsodium-dev libssl-dev libsystemd-dev \
	libtinfo-dev libtool libudev-dev libusb-1.0-0-dev make moreutils pkg-config python3 python3 python3-pip \
	librocksdb-dev rocksdb-tools rsync secure-delete sqlite sqlite3 systemd tcptraceroute tmux zlib1g-dev \
	dos2unix ifupdown inetutils-traceroute libbz2-dev liblz4-dev libsnappy-dev cython cython3 libnuma-dev \
	    1>> "$BUILDLOG" 2>&1 \
	        || err_exit 71 "$0: Failed to install apt-get dependencies; aborting"
				
# Make sure some other basic prerequisites are correctly installed
$APTINSTALLER install --reinstall build-essential 1>> "$BUILDLOG" 2>&1
$APTINSTALLER install --reinstall gcc             1>> "$BUILDLOG" 2>&1
dpkg-reconfigure build-essential                  1>> "$BUILDLOG" 2>&1
dpkg-reconfigure gcc                              1>> "$BUILDLOG" 2>&1
$APTINSTALLER install llvm-9                      1>> "$BUILDLOG" 2>&1 || err_exit 71 "$0: Failed to install llvm-9; aborting"
$APTINSTALLER install rpi-imager                  1>> "$BUILDLOG" 2>&1 \
	|| snap install rpi-imager 					  1>> "$BUILDLOG" 2>&1  # If not present, no biggie
$APTINSTALLER install rpi-eeprom                  1>> "$BUILDLOG" 2>&1  # Might not be present, and if so, no biggie

EEPROM_UPDATE="$(which rpi-eeprom-update 2>&1)"
if [ ".$EEPROM_UPDATE" != '.' ] && [ -x "$EEPROM_UPDATE" ]; then 
	if $EEPROM_UPDATE | egrep -q 'BOOTLOADER: *up-to-date'; then
		debug "Eeprom up to date; skipping update"
	else
		debug "Updating eeprom: $EEPROM_UPDATE -a"
		$EEPROM_UPDATE -a 1>> "$BUILDLOG" 2>&1
    fi
fi

debug "Making sure SSH service is enabled and started"
$APTINSTALLER install net-tools openssh-server    1>> "$BUILDLOG" 2>&1
systemctl daemon-reload 						  1>> "$BUILDLOG" 2>&1
systemctl enable ssh                              1>> "$BUILDLOG" 2>&1
systemctl start ssh                               1>> "$BUILDLOG" 2>&1
systemctl status ssh 							  1>> "$BUILDLOG" 2>&1 \
    err_exit 136 "$0: Problem enabling (or starting) ssh service; aborting (run 'systemctl status ssh')"

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
			cat << _EOF >> "$BOOTCONFIG"

over_voltage=5
arm_freq=$OVERCLOCK_SPEED
# gpu_freq=700
# gpu_mem=256
# sdram_freq=3200

_EOF
		fi
	fi
fi

# Set up restrictive firewall - just SSH and RDP, plus Cardano node $LISTENPORT
#
if [ ".$SKIP_FIREWALL_CONFIG" = '.Y' ] || [ ".$DONT_OVERWRITE" = '.Y' ]; then
    debug "Skipping firewall configuration at user request"
else
    debug "Setting up firewall (using ufw)"
	ufw --force reset            1>> "$BUILDLOG" 2>&1
	if apt-cache pkgnames | egrep -q '^ufw$'; then
		ufw disable 1>> "$BUILDLOG" # install ufw if not present
	else
		$APTINSTALLER install ufw 1>> "$BUILDLOG" 2>&1
	fi
	# echo "Installing firewall with only ports 22, 3000, 3001, and 3389 open..."
	ufw default deny incoming    1>> "$BUILDLOG" 2>&1
	ufw default allow outgoing   1>> "$BUILDLOG" 2>&1
	for netw in $(echo "$MY_SUBNETS" | sed 's/ *, */ /g'); do
		ufw allow from "$netw" to any port ssh 1>> "$BUILDLOG" 2>&1
	done
	# Assume cardano-node is publicly available, so don't restrict 
	ufw allow "$LISTENPORT/tcp"  1>> "$BUILDLOG" 2>&1
	# ufw allow 3001/tcp           1>> "$BUILDLOG"
	# ufw allow 6000/tcp           1>> "$BUILDLOG"
	# ufw deny from [IP.address] to any port [number]
	# ufw delete [rule_number]
	ufw --force enable           1>> "$BUILDLOG" 2>&1
	debug "Firewall configured; rule summary (please check and fix later on):"
	[ -z "$DEBUG" ] || ufw status numbered  # show what's going on

	# Add RDP service if INSTALLRDP is Y
	#
	if [ ".$INSTALLRDP" = ".Y" ]; then
	    debug "Setting up RDP; please check setup by hand when done"
		$APTINSTALLER install xrdp     1>> "$BUILDLOG" 2>&1
		$APTINSTALLER install tasksel  1>> "$BUILDLOG" 2>&1
		tasksel install ubuntu-desktop 1>> "$BUILDLOG" 2>&1
		systemctl enable xrdp          1>> "$BUILDLOG" 2>&1
		systemctl start xrdp           1>> "$BUILDLOG" 2>&1
		systemctl status xrdp   1>> "$BUILDLOG" 2>&1 \
    		err_exit 137 "$0: Problem enabling (or starting) xrdp; aborting (run 'systemctl status xrdp')"

		RUID=$(who | awk 'FNR == 1 {print $1}')
		RUSER_UID=$(id -u ${RUID})
		sudo -u "${RUID}" DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/${RUSER_UID}/bus" gsettings set org.gnome.settings-daemon.plugins.power sleep-inactive-battery-type 'nothing' 2>> "$BUILDLOG"
		sudo -u "${RUID}" DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/${RUSER_UID}/bus" gsettings set org.gnome.settings-daemon.plugins.power sleep-inactive-ac-type 'nothing'      2>> "$BUILDLOG"
		dconf update 2>> "$BUILDLOG"
		systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target 1>> "$BUILDLOG" 2>&1
		ufw allow from "$MY_SUBNETS" to any port 3389 1>> "$BUILDLOG" 2>&1
	fi
fi

# Add hidden WiFi network if -h <network SSID> was supplied; I don't recommend WiFi except for setup
#
if [ ".$HIDDENWIFI" != '.' ]; then
    debug "Setting up hidden WiFi network, $HIDDENWIFI; please check by hand when done"
	if [ -f "$WPA_SUPPLICANT" ]; then
		: do nothing
	else
		$APTINSTALLER install wpasupplicant 1>> "$BUILDLOG" 2>&1
		cat << _EOF > "$WPA_SUPPLICANT"
country=US
ctrl_interface=DIR=/var/run/wpa_supplicant GROUP=netdev
update_config=1
	
_EOF
	fi
	if egrep -q '^[	 ]*ssid="$HIDDENWIFI"' "$WPA_SUPPLICANT"; then
		: do nothing
	else
		cat << _EOF >> "$WPA_SUPPLICANT"

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
		cat << _EOF >> "/etc/systemd/system/network-wireless@.service"
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
	systemctl start wpa_supplicant.service    1>> "$BUILDLOG"
	systemctl status wpa_supplicant.service   1>> "$BUILDLOG" 2>&1 \
    	err_exit 137 "$0: Problem enabling (or starting) wpa_supplicant.service service; aborting (run 'systemctl status wpa_supplicant.service')"
	# renew DHCP leases
	dhclient "$WLAN" 1>> "$BUILDLOG" 2>&1
fi

# DHCP to a specifi VLAN if asked (e.g., -v 5)
if [ ".$VLAN_NUMBER" != '.' ]; then
    NETPLAN_FILE=$(egrep -l eth0 /etc/netplan/* | head -1)
	if [ ".$NETPLAN_FILE" = '.' ] || egrep -q 'vlans:' "$NETPLAN_FILE"; then
		debug "Skipping VLAN $VLAN_NUMBER interface configuration; $NETPLAN_FILE already has VLANs.  Do this part manually."
	else
    	sed -i "$NETPLAN_FILE" -e '/eth0:/,/wlan0:|vlans:/ { s|^\([ 	]*dhcp4:[ 	]*\)true|\1false|gi }'
		cat << _EOF >> "$NETPLAN_FILE"
    vlans:
        vlan$VLAN_NUMBER:
            id: $VLAN_NUMBER
            link: eth0
            dhcp4: true
_EOF
    debug "You will need to run: 'netplan apply' before you can use the vlan${VLAN_NUMBER} interface"
	fi
fi

# Add cardano user (or whatever install user is used) and lock password
#
debug "Checking and (if need be) making install user: ${INSTALL_USER}"
id "$INSTALL_USER" 1>> "$BUILDLOG"  2>&1 \
    || useradd -m -s /bin/bash "$INSTALL_USER" 1>> "$BUILDLOG"
# The account for the install user (which will run cardano-node) should be locked
passwd -l "$INSTALL_USER"                   1>> "$BUILDLOG"
usermod -a -G users "$INSTALL_USER"         1>> "$BUILDLOG" 2>&1

# Install GHC, cabal
#
cd "$BUILDDIR"
debug "Downloading: ghc-${GHCVERSION}"
$WGET "http://downloads.haskell.org/~ghc/${GHCVERSION}/ghc-${GHCVERSION}-${GHCARCHITECTURE}-${GHCOS}-linux.tar.xz" -O "ghc-${GHCVERSION}-${GHCARCHITECTURE}-${GHCOS}-linux.tar.xz"
if [ ".$SKIP_RECOMPILE" != '.Y' ]; then
    debug "Building: ghc-${GHCVERSION}"
	'rm' -rf "ghc-${GHCVERSION}"
	tar -xf "ghc-${GHCVERSION}-${GHCARCHITECTURE}-${GHCOS}-linux.tar.xz" 1>> "$BUILDLOG"
	cd "ghc-${GHCVERSION}"
	debug "Running: ./configure CONF_CC_OPTS_STAGE2=\"$GCCMARMARG $GHC_GCC_ARCH\" CFLAGS=\"$GCCMARMARG $GHC_GCC_ARCH\""
	./configure CONF_CC_OPTS_STAGE2="$GCCMARMARG $GHC_GCC_ARCH" CFLAGS="$GCCMARMARG $GHC_GCC_ARCH" 1>> "$BUILDLOG"
fi
debug "Installing: ghc-${GHCVERSION}"
$MAKE install 1>> "$BUILDLOG"
#
cd "$BUILDDIR"
debug "Downloading and installing cabal: ${CABALDOWNLOADPREFIX}-${CABALARCHITECTURE}-${CABAL_OS}.tar.xz"

# Now do cabal; we'll pull binaries in this case
#
$WGET "${CABALDOWNLOADPREFIX}-${CABALARCHITECTURE}-${CABAL_OS}.tar.xz" -O "cabal-${CABALARCHITECTURE}-${CABAL_OS}.tar.xz" \
    || err_exit 48 "$0: Unable to download cabal; aborting"
tar -xf "cabal-${CABALARCHITECTURE}-${CABAL_OS}.tar.xz" 1>> "$BUILDLOG"
cp cabal "$CABAL"             || err_exit 66 "$0: Failed to copy cabal into position ($CABAL); aborting"
chown root.root "$CABAL"
chmod 755 "$CABAL"
if $CABAL update 1>> "$BUILDLOG" 2>&1; then
	debug "Successfully updated $CABAL"
else
	pushd ~ 1>> "$BUILDLOG" 2>&1 # Work around bug in cabal
	($CABAL update 2>&1 | tee -a "$BUILDLOG") || err_exit 67 "$0: Failed to run '$CABAL update'; aborting"
	popd 	1>> "$BUILDLOG" 2>&1
fi

# Install wacky Cardano version of libsodium unless told to use a different -w $LIBSODIUM_VERSION
#
debug "Downloading and installing libsodium, version $LIBSODIUM_VERSION"
cd "$BUILDDIR"
'rm' -rf libsodium
git clone https://github.com/input-output-hk/libsodium 1>> "$BUILDLOG" 2>&1
cd libsodium
git checkout "$LIBSODIUM_VERSION"    1>> "$BUILDLOG" 2>&1 || err_exit 77 "$0: Failed to 'git checkout' libsodium version "$LIBSODIUM_VERSION"; aborting"
./autogen.sh                         1>> "$BUILDLOG" 2>&1
./configure                          1>> "$BUILDLOG" 2>&1
$MAKE                                1>> "$BUILDLOG" 2>&1
$MAKE install                        1>> "$BUILDLOG"      || err_exit 78 "$0: Failed to 'git checkout' libsodium version "$LIBSODIUM_VERSION"; aborting"
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
		err_exit 49 "$0: Unable to fetch node build number; aborting")
debug "NODE_BUILD_NUM discovered (used to fetch latest config files): $NODE_BUILD_NUM" 
for bashrcfile in "/home/${BUILD_USER}/.bashrc" "$INSTALLDIR/.bashrc"; do
	for envvar in 'LD_LIBRARY_PATH' 'PKG_CONFIG_PATH' 'NODE_HOME' 'NODE_CONFIG' 'NODE_BUILD_NUM' 'PATH' 'CARDANO_NODE_SOCKET_PATH'; do
		case "${envvar}" in
			'LD_LIBRARY_PATH'          ) SUBSTITUTION="\"/usr/local/lib:${INSTALLDIR}/lib:\${LD_LIBRARY_PATH}\"" ;;
			'PKG_CONFIG_PATH'          ) SUBSTITUTION="\"/usr/local/lib/pkgconfig:${INSTALLDIR}/pkgconfig:\${PKG_CONFIG_PATH}\"" ;;
			'NODE_HOME'                ) SUBSTITUTION="\"${INSTALLDIR}\"" ;;
			'NODE_CONFIG'              ) SUBSTITUTION="\"${BLOCKCHAINNETWORK}\"" ;;
			'NODE_BUILD_NUM'           ) SUBSTITUTION="\"${NODE_BUILD_NUM}\"" ;;
			'PATH'                     ) SUBSTITUTION="\"/usr/local/bin:${INSTALLDIR}:\${PATH}\"" ;;
			'CARDANO_NODE_SOCKET_PATH' ) SUBSTITUTION="\"${INSTALLDIR}/sockets/core-node.socket\"" ;;
			\? ) err_exit 91 "0: Coding error in environment variable case statement; aborting" ;;
		esac
		if egrep -q "^ *export +${envvar}=" "$bashrcfile"; then
		    debug "Changing variable in $bashrcfile: export ${envvar}=.*$ -> export ${envvar}=${SUBSTITUTION}"
			sed -i "$bashrcfile" -e "s|^ *export +\(${envvar}\)=.*$\+|export \1=${SUBSTITUTION}|g"
		else
		    debug "Appending to $bashrcfile: ${envvar}=${SUBSTITUTION}" 
			echo "export ${envvar}=${SUBSTITUTION}" >> $bashrcfile
		fi
    done
done
. "/home/${BUILD_USER}/.bashrc"

# Install cardano-node
#
# BACKUP PREVIOUS SOURCES AND DOWNLOAD 1.25.1
#
debug "Downloading, configuring, and (if no -x argument) building: cardano-node and cardano-cli" 
cd "$BUILDDIR"
'rm' -rf cardano-node-OLD
'mv' -f cardano-node cardano-node-OLD
git clone "https://github.com/input-output-hk/cardano-node.git" 1>> "$BUILDLOG" 2>&1
cd cardano-node
git fetch --all --recurse-submodules --tags  1>> "$BUILDLOG" 2>&1
git checkout "tags/${CARDANONODEVERSION}"    1>> "$BUILDLOG" 2>&1 || err_exit 79 "$0: Failed to 'git checkout' cardano-node; aborting"
#
# CONFIGURE BUILD OPTIONS
#
$CABAL configure -O0 -w "ghc-${GHCVERSION}" 1>> "$BUILDLOG"  2>&1
'rm' -rf "$BUILDDIR/cardano-node/dist-newstyle/build/x86_64-linux/ghc-${GHCVERSION}"
echo "package cardano-crypto-praos" >  "${BUILDDIR}/cabal.project.local"
echo "  flags: -external-libsodium-vrf" >>  "${BUILDDIR}/cabal.project.local"
echo -e "package cardano-crypto-praos\n flags: -external-libsodium-vrf" > "${BUILDDIR}/cabal.project.local"
#
# BUILD
#
if $CABAL build cardano-cli cardano-node 1>> "$BUILDLOG" 2>&1; then
	: all good
else
	if [ ".$DEBUG" = '.Y' ]; then
		# Do some more intense debugging if the build fails
		CARDANOBUILDTMPFILE=$(mktemp ${TMPDIR:-/tmp}"/${0}.XXXXXXXXXX")
		debug "Failed to build cardano-node; now verbose debugging to: $CARDANOBUILDTMPFILE"
		strace $CABAL build cardano-cli cardano-node 2> "$CARDANOBUILDTMPFILE" \
			|| err_exit 88 "$0: Failed to build cardano-node; check $CARDANOBUILDTMPFILE"
		rm -f "$CARDANOBUILDTMPFILE"
	else
		err_exit 87 "$0: Failed to build cardano-cli and cardano-node; aborting"
	fi
fi
#
# Stop the node so we can replace binaries
#
debug "Stopping cardano-node service, if running (need to do this to replace binaries)" 
if systemctl list-unit-files --type=service --state=enabled | egrep -q 'cardano-node'; then
	systemctl stop cardano-node    1>> "$BUILDLOG" 2>&1
	systemctl disable cardano-node 1>> "$BUILDLOG" 2>&1 \
		|| err_exit 57 "$0: Failed to disable running cardano-node service; aborting"
fi
# Just in case, kill everything run by the install user
killall -s SIGINT  -u "$INSTALL_USER"  1>> "$BUILDLOG" 2>&1; sleep 10  # Wait a bit before delivering death blow
killall -s SIGKILL -u "$INSTALL_USER"  1>> "$BUILDLOG" 2>&1
#
# COPY NEW BINARIES
#
debug "Installing binaries for cardano-node and cardano-cli" 
$CABAL install --installdir "$INSTALLDIR" cardano-cli cardano-node 1>> "$BUILDLOG" 2>&1
if [ ".$SKIP_RECOMPILE" != '.Y' ]; then
    # If we recompiled, remove symlinks if they exist in prep for copying in new binaries
	[ -L "$INSTALLDIR/cardano-cli" ] && rm -f "$INSTALLDIR/cardano-cli"
	[ -L "$INSTALLDIR/cardano-node" ] && rm -f "$INSTALLDIR/cardano-node"
fi
if [ -x "$INSTALLDIR/cardano-cli" ]; then
    : do nothing
else
    cp $(find "$BUILDDIR/cardano-node" -type f -name cardano-cli ! -path '*OLD*') "$INSTALLDIR/cardano-cli"
    cp $(find "$BUILDDIR/cardano-node" -type f -name cardano-node ! -path '*OLD*') "$INSTALLDIR/cardano-node"
fi
[ -x "$INSTALLDIR/cardano-node" ] || err_exit 147 "$0: Failed to install $INSTALLDIR/cardano-node; aborting"
debug "Installed cardano-node version: $(${INSTALLDIR}/cardano-node version | head -1)"
debug "Installed cardano-cli version: $(${INSTALLDIR}/cardano-cli version | head -1)"

# Set up directory structure in the $INSTALLDIR (OK if they exist already)
for subdir in 'files' "db-${BLOCKCHAINNETWORK}" 'guild-db' 'logs' 'scripts' 'sockets' 'priv' 'pkgconfig'; do
    mkdir -p "${INSTALLDIR}/$subdir"
    chown -R "${INSTALL_USER}.${INSTALL_USER}" "${INSTALLDIR}/$subdir" 2>/dev/null
	find "${INSTALLDIR}/$subdir" -type d -exec chmod "2775" {} \;
	find "${INSTALLDIR}/$subdir" -type f -exec chmod "0664" {} \;
done

# UPDATE mainnet-config.json and related files to latest version and start node
#
if [ ".$DONT_OVERWRITE" != '.Y' ]; then
    debug "Downloading new versions of various files, including: $CARDANO_FILEDIR/${BLOCKCHAINNETWORK}-config.json"
	cd "$INSTALLDIR"
	debug "Saving the configuration of the EKG port, PROMETHEUS port, and listening address (if extant)"
	export CURRENT_EKG_PORT=$(jq -r .hasEKG "${CARDANO_FILEDIR}/${BLOCKCHAINNETWORK}-config.json")
	export CURRENT_PROMETHEUS_PORT=$(jq -r .hasPrometheus[1] "${CARDANO_FILEDIR}/${BLOCKCHAINNETWORK}-config.json")
	export CURRENT_PROMETHEUS_LISTEN=$(jq -r .hasPrometheus[0] "${CARDANO_FILEDIR}/${BLOCKCHAINNETWORK}-config.json")
	debug "Fetching json files from IOHK; starting with: https://hydra.iohk.io/build/${NODE_BUILD_NUM}/download/1/${BLOCKCHAINNETWORK}-config.json "
	$WGET "https://hydra.iohk.io/build/${NODE_BUILD_NUM}/download/1/${BLOCKCHAINNETWORK}-config.json"          -O "${CARDANO_FILEDIR}/${BLOCKCHAINNETWORK}-config.json"
	$WGET "https://hydra.iohk.io/build/${NODE_BUILD_NUM}/download/1/${BLOCKCHAINNETWORK}-topology.json"        -O "${CARDANO_FILEDIR}/${BLOCKCHAINNETWORK}-topology.json"
	$WGET "https://hydra.iohk.io/build/${NODE_BUILD_NUM}/download/1/${BLOCKCHAINNETWORK}-byron-genesis.json"   -O "${CARDANO_FILEDIR}/${BLOCKCHAINNETWORK}-byron-genesis.json"
	$WGET "https://hydra.iohk.io/build/${NODE_BUILD_NUM}/download/1/${BLOCKCHAINNETWORK}-shelley-genesis.json" -O "${CARDANO_FILEDIR}/${BLOCKCHAINNETWORK}-shelley-genesis.json"
	sed -i "${CARDANO_FILEDIR}/${BLOCKCHAINNETWORK}-config.json" -e "s/TraceBlockFetchDecisions\": false/TraceBlockFetchDecisions\": true/g"
	# Restoring previous parameters to the config file:
	if [ ".$CURRENT_EKG_PORT" != '.' ] && egrep -q 'CURRENT_EKG_PORT' "${CARDANO_FILEDIR}/${BLOCKCHAINNETWORK}-config.json"; then 
		jq .hasEKG="${CURRENT_EKG_PORT}"                         "${CARDANO_FILEDIR}/${BLOCKCHAINNETWORK}-config.json" |  sponge "$CARDANO_FILEDIR/${BLOCKCHAINNETWORK}-config.json" 
		jq .hasPrometheus[0]="\"${CURRENT_PROMETHEUS_LISTEN}\""  "${CARDANO_FILEDIR}/${BLOCKCHAINNETWORK}-config.json" |  sponge "$CARDANO_FILEDIR/${BLOCKCHAINNETWORK}-config.json" 
		jq .hasPrometheus[1]="${CURRENT_PROMETHEUS_PORT}"        "${CARDANO_FILEDIR}/${BLOCKCHAINNETWORK}-config.json" |  sponge "$CARDANO_FILEDIR/${BLOCKCHAINNETWORK}-config.json" 
	fi
	sed -i "$CARDANO_FILEDIR/${BLOCKCHAINNETWORK}-config.json" -e "s/TraceBlockFetchDecisions\": +false/TraceBlockFetchDecisions\": true/g"
	[ -s "$CARDANO_FILEDIR/${BLOCKCHAINNETWORK}-config.json" ] || err_exit 58 "0: Failed to download ${BLOCKCHAINNETWORK}-config.json from https://hydra.iohk.io/build/${NODE_BUILD_NUM}/download/1/"

	# Set up startup script
	#
	SYSTEMSTARTUPSCRIPT="/lib/systemd/system/cardano-node.service"
	debug "(Re)creating cardano-node start-up script: $SYSTEMSTARTUPSCRIPT"
	[ -f "$NODE_CONFIG_FILE" ] || err_exit 28 "$0: Can't find config.yaml file, "$NODE_CONFIG_FILE"; aborting"
	#
	# Figure out where special keys, certs are and add them to startup script later on, if need be
	CERTKEYARGS=''
	KEYCOUNT=0
	[ -s "$INSTALLDIR/kes.skey"]  && KEYCOUNT=$(expr "$KEYCOUNT" + 1)
	[ -s "$INSTALLDIR/vrf.skey"]  && KEYCOUNT=$(expr "$KEYCOUNT" + 1)
	[ -s "$INSTALLDIR/node.cert"] && KEYCOUNT=$(expr "$KEYCOUNT" + 1)
	if [ "${LISTENPORT}" -ge 6000 ]; then
		# Assuming we're a block producer if -p <LISTENPORT> is >= 6000
		if [ "$KEYCOUNT" -ge 3 ]; then
			CERTKEYARGS="--shelley-kes-key $INSTALLDIR/kes.skey --shelley-vrf-key $INSTALLDIR/vrf.skey --shelley-operational-certificate $INSTALLDIR/node.cert"
		else
			# Go ahead and configure if key/cert is missing, but don't run the node with them
			[ "$KEYCOUNT" -ge 1 ] && debug "Not all needed keys/certs are present in $INSTALLDIR; ignoring them (please generate!)"
		fi
	else
		# We assume if port is less than 6000 (usually 3000 or 3001), we're a relay-only node, not a block producer
		[ "$KEYCOUNT" -ge 3 ] && debug "Not running as block producer (port < 6000); ignoring key/cert files in $INSTALLDIR"
	fi
	cat << _EOF > "$INSTALLDIR/cardano-node-starting-env.txt"
PATH="/usr/local/bin:$INSTALLDIR:\$PATH"
LD_LIBRARY_PATH="/usr/local/lib:$INSTALLDIR/lib:\$LD_LIBRARY_PATH"
PKG_CONFIG_PATH="/usr/local/lib/pkgconfig:$INSTALLDIR/pkgconfig:\$PKG_CONFIG_PATH"
_EOF
	chmod 0644 "$INSTALLDIR/cardano-node-starting-env.txt"
	[ -z "${IPV4_ADDRESS}" ] || IPV4ARG="--host-addr '$IPV4_ADDRESS'"
	[ -z "${IPV6_ADDRESS}" ] || IPV6ARG="--host-ipv6-addr '$IPV6_ADDRESS'"
	cat << _EOF > "$SYSTEMSTARTUPSCRIPT"
# Make sure cardano-node is installed as a service
[Unit]
Description=Cardano Node start script
After=multi-user.target
 
[Service]
User=$INSTALL_USER
KillSignal=SIGINT
RestartKillSignal=SIGINT
StandardOutput=journal
StandardError=journal
SyslogIdentifier=cardano-node
TimeoutStartSec=0
Type=simple
KillMode=process
WorkingDirectory=$INSTALLDIR
ExecStart=$INSTALLDIR/cardano-node run --socket-path $INSTALLDIR/sockets/core-node.socket --config $NODE_CONFIG_FILE $IPV4ARG $IPV6ARG --port $LISTENPORT --topology $CARDANO_FILEDIR/${BLOCKCHAINNETWORK}-topology.json --database-path ${CARDANO_DBDIR}/ $CERTKEYARGS
Restart=on-failure
RestartSec=12s
LimitNOFILE=32768
 
[Install]
WantedBy=multi-user.target

_EOF
	chown root.root "$SYSTEMSTARTUPSCRIPT"
	chmod 0644 "$SYSTEMSTARTUPSCRIPT"
fi
debug "Cardano node will be started (later): $INSTALLDIR/cardano-node run --socket-path $INSTALLDIR/sockets/core-node.socket --config $NODE_CONFIG_FILE $IPV4ARG $IPV6ARG --port $LISTENPORT --topology $CARDANO_FILEDIR/${BLOCKCHAINNETWORK}-topology.json --database-path ${CARDANO_DBDIR}/"

# Modify topology file; add -R <relay-ip:port> information
#
TMP_TOPOLOGY_FILE=$(mktemp ${TMPDIR:-/tmp}"/${0}.XXXXXXXXXX")
BLOCKPRODUCERNODE="{ \"addr\": \"$RELAY_ADDRESS\", \"port\": $RELAY_PORT, \"valency\": 1 }"
if [[ ! -s "${CARDANO_FILEDIR}/${BLOCKCHAINNETWORK}-topology.json" ]]; then
	# Topology file is empty; just create the whole thing all at once...
	if [[ ! -z "${RELAY_ADDRESS}" ]]; then
		# ...if, that is, we have a relay address (-R argment)
		echo -e "{ \"Producers\": [ $BLOCKPRODUCERNODE ] }\n" | jq >> "$TMP_TOPOLOGY_FILE"
	fi
else
	SUBSCRIPT=''
	# If we are a block producer (port 6000 or higher - assumed to be a producer node)
	if [ "${LISTENPORT}" -ge 6000 ]; then
		[ -z "${RELAY_ADDRESS}" ] \
			&& err_exit 154 "Block producer really needs -R <relay-ip:port>; rerun with this argument supplied; (for now) aborting"
		COUNTER=0
		for keyAndVal in $(jq -r '.Producers[]|{addr}|to_entries[]|(.value)' "${CARDANO_FILEDIR}/${BLOCKCHAINNETWORK}-topology.json"); do
			COUNTER=$(expr $COUNTER + 1)
			if echo "$keyAndVal" | egrep -q 'iohk|cardano|emurgo'; then
				SUBSCRIPT=$(expr $COUNTER - 1)
				break
			fi
		done
		if [[ ! -z "$SUBSCRIPT" ]]; then
			debug "We're a block producer; deleting Producers[${SUBSCRIPT}] from ${CARDANO_FILEDIR}/${BLOCKCHAINNETWORK}-topology.json"
			jq "del(.Producers[${SUBSCRIPT}])" "${CARDANO_FILEDIR}/${BLOCKCHAINNETWORK}-topology.json" >> "$TMP_TOPOLOGY_FILE"
			cat < "$TMP_TOPOLOGY_FILE" > "${CARDANO_FILEDIR}/${BLOCKCHAINNETWORK}-topology.json"
			cat < /dev/null > "$TMP_TOPOLOGY_FILE"
		fi
	fi
	# Everyone gets to here (block producers and relay nodes alike), to add the relay address to the topology file
	if [ -z "${RELAY_ADDRESS}" ]; then
		debug "No -R <relay-ip:port> given (no prob); leaving topology file as is"
	else
		ALREADY_PRESENT_IN_TOPOLOGY_FILE=''
		for keyAndVal in $(jq -r '.Producers[]|{addr,port}|to_entries[]|(.key+"="+(.value | tostring))' "${CARDANO_FILEDIR}/${BLOCKCHAINNETWORK}-topology.json" | xargs | tr ' ' ','); do
			if [ ".$keyAndVal" = ".addr=${RELAY_ADDRESS},port=${RELAY_PORT}" ]; then
				ALREADY_PRESENT_IN_TOPOLOGY_FILE='Y'
				break
			fi
		done
		if [ -z "$ALREADY_PRESENT_IN_TOPOLOGY_FILE" ]; then
			PRODUCER_COUNT=$(jq '.Producers|length' "${CARDANO_FILEDIR}/${BLOCKCHAINNETWORK}-topology.json")
			jq ".Producers[$PRODUCER_COUNT]|=$BLOCKPRODUCERNODE" "${CARDANO_FILEDIR}/${BLOCKCHAINNETWORK}-topology.json" >> "$TMP_TOPOLOGY_FILE"
			cat < "$TMP_TOPOLOGY_FILE" > "${CARDANO_FILEDIR}/${BLOCKCHAINNETWORK}-topology.json"
			cat < /dev/null > "$TMP_TOPOLOGY_FILE"
		else
			debug "Topology file already has a Producers element for ${RELAY_ADDRESS}:${RELAY_PORT}; no need to add"
		fi
	fi
fi
rm -f "$TMP_TOPOLOGY_FILE"
[ -s "${CARDANO_FILEDIR}/${BLOCKCHAINNETWORK}-topology.json" ] \
	|| err_exit 146 "$0: Empty topology file; fix by hand: ${CARDANO_FILEDIR}/${BLOCKCHAINNETWORK}-topology.json; aborting"

# Ensure cardano-node auto-starts
#
debug "Setting up cardano-node as system service"
systemctl daemon-reload	
systemctl enable cardano-node 1>> "$BUILDLOG" 2>&1
systemctl start cardano-node  1>> "$BUILDLOG" 2>&1
(systemctl status cardano-node | tee -a "$BUILDLOG" 2>&1 | egrep -q 'ctive.*unning') \
    || err_exit 138 "$0: Problem enabling (or starting) cardano-node service; aborting (run 'systemctl status cardano-node')"

#
# UPDATE gLiveView.sh
#
debug "Downloading gLiveView.sh to: ${CARDANO_SCRIPTDIR}"
cd "$INSTALLDIR"
$WGET "${GUILDREPO_RAW_URL}/scripts/cnode-helper-scripts/gLiveView.sh" -O "${CARDANO_SCRIPTDIR}/gLiveView.sh" \
    || err_exit 108 "$0: Failed to fetch ${GUILDREPO_RAW_URL}/scripts/cnode-helper-scripts/gLiveView.sh; aborting"
chmod 755 "${CARDANO_SCRIPTDIR}/gLiveView.sh"
if [ ".$DONT_OVERWRITE" != '.Y' ]; then
	$WGET "${GUILDREPO_RAW_URL}/scripts/cnode-helper-scripts/env" -O "${CARDANO_SCRIPTDIR}/env" \
		|| err_exit 109 "$0: Failed to fetch ${CARDANO_SCRIPTDIR}/scripts/cnode-helper-scripts/env; aborting"
	debug "Setting config file in gLiveView script: ^\#* *CONFIG=\"\${CNODE_HOME}/[^/]*/[^/.]*\.json -> CONFIG=\"$NODE_CONFIG_FILE\""
	debug "Setting socket in gLiveView script: ^\#* *SOCKET=\"\${CNODE_HOME}/[^/]*/[^/.]*\.socket -> SOCKET=\"$INSTALLDIR/sockets/core-node.socket\""
	sed -i "${CARDANO_SCRIPTDIR}/env" \
		-e "s|^\#* *CONFIG=\"\${CNODE_HOME}/[^/]*/[^/.]*\.json\"|CONFIG=\"$NODE_CONFIG_FILE\"|g" \
		-e "s|^\#* *SOCKET=\"\${CNODE_HOME}/[^/]*/[^/.]*\.socket\"|SOCKET=\"$INSTALLDIR/sockets/core-node.socket\"|g" \
			|| err_exit 109 "$0: Failed to modify gLiveView 'env' file, ${CARDANO_SCRIPTDIR}/env; aborting"
fi

# install other utilities
#
debug "Installing python-cardano and cardano-tools using $PIP"
$PIP install --upgrade pip   1>> "$BUILDLOG" 2>&1
$PIP install pip-tools       1>> "$BUILDLOG" 2>&1
$PIP install python-cardano  1>> "$BUILDLOG" 2>&1
$PIP install cardano-tools   1>> "$BUILDLOG" \
    || err_exit 117 "$0: Unable to install cardano tools: $PIP install cardano-tools; aborting"

debug "Tasks:"
debug "  You may have to clear ${CARDANO_DBDIR} before running cardano-node again"
debug "  It is recommended that the (powerful) $PIUSER account be locked or otherwise secured"
debug "  Check networking and firewall configuration (run 'ifconfig' and 'ufw status numbered')"
debug "  Follow syslogged activity by running: journalctl --unit=cardano-node --follow"
debug "  Monitor node activity by running: cd $CARDANO_SCRIPTDIR; bash ./gLiveView.sh"
debug "  Please examine topology file; run: less \"${CARDANO_FILEDIR}/${BLOCKCHAINNETWORK}-topology.json\""
(date +"%Z %z" | egrep -q UTC) \
    && debug "  Please also set the timezone (e.g., timedatectl set-timezone 'America/Chicago')"

rm -f "$TEMPLOCKFILE" 2> /dev/null
rm -f "$TMPFILE"      2> /dev/null
rm -f "$LOGFILE"      2> /dev/null
