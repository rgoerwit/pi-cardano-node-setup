#!/bin/bash
#
#############################################################################
#
#  Copyright 2021 Richard L. Goerwitz III
#
#    This code may be freely used for commercial or noncommercial
#    purposes.  I make no guarantee, however, about this code's
#    correctness or fitness for any particular purpose.  Use it at
#    your own risk.
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
if [ -e "$SCRIPT_PATH/pi-cardano-node-fake-code.sh" ]; then
	SCRIPT_PATH=$(readlink -e -- "$0" | sed 's:/[^/]*$::')
	. "$SCRIPT_PATH/pi-cardano-node-fake-code.sh" \
		|| err_exit 47 "$0: Can't execute $SCRIPT_PATH/pi-cardano-node-fake-code.sh"
fi

usage() {
  cat << _EOF 1>&2

Usage: $PROGNAME [-4 <external IPV4>] [-6 <external IPV6>] [-b <builduser>] [-c <node config filename>] [[-h <SID:password>] [-m <seconds>] [-n <mainnet|testnet|launchpad|guild|staging>] [-o <overclock speed>] [-p <port>] [-r] [-s <subnet>] [-u <installuser>] [-w <libsodium-version-number>] [-x]

Sets up a Cardano relay node on a new Pi 4 running Ubuntu LTS distro
New (overclocking) mainnet setup on TCP port 3000:   $PROGNAME -b builduser -u cardano -n mainnet -o 2100 -p 3000 
Refresh of existing mainnet setup (keep existing config files):  $PROGNAME -d -b builduser -u cardano -n mainnet

-4    External IPv4 address (defaults to 0.0.0.0)
-6    External IPv6 address (defaults to NULL)
-b    User whose home directory will be used for compiling (defaults to 'builduser')
-c    Node configuration file (defaults to <install user home dir>/<network>-config.json)
-d    Don't overwrite config files, or 'env' file for gLiveView
-h    Install (naturally, hidden) WiFi; format:  SID:password (only use WiFi on the relay, not block producer)
-m    Maximum time in seconds that you allow the file download operation to take before aborting (Default: 80s)
-n    Connect to specified network instead of mainnet network (Default: mainnet)
      e.g.: -n testnet (alternatives: allegra launchpad mainnet mary_qa shelley_qa staging testnet...)
-o    Overclocking value (should be something like, e.g., 2100 for a Pi 4)
-p    Listen port (default 3000)
-r    Install RDP
-s    Subnet where server resides (e.g., 192.168.34.0/24); only used if you enable RDP (-r) (not recommended)
-u    User who will run the executables and in whose home directory the executables will be installed
-w    Specify a libsodium version (defaults to the wacky version the Cardano project recommends)
-x    Don't recompile anything big
_EOF
  exit 1
}

while getopts 4:6::bc:dfh:m:n:o:p:rs:u:w:x opt; do
  case ${opt} in
    '4' ) IPV4_ADDRESS="${OPTARG}" ;;
    '6' ) IPV6_ADDRESS="${OPTARG}" ;;
	b ) BUILD_USER="${OPTARG}" ;;
	c ) NODE_CONFIG_FILE="${OPTARG}" ;;
	d ) DONT_OVERWRITE='Y' ;;
    h ) HIDDEN_WIFI_INFO="${OPTARG}" ;;
    m ) WGET_TIMEOUT="${OPTARG}" ;;
    n ) BLOCKCHAINNETWORK="${OPTARG}" ;;
	o ) OVERCLOCK_SPEED="${OPTARG}" ;;
    p ) LISTENPORT="${OPTARG}" ;;
    r ) INSTALLRDP='Y' ;;
	s ) MY_SUBNET="${OPTARG}" ;;
    u ) INSTALL_USER="${OPTARG}" ;;
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

[ -z "${BUILD_USER}" ] && BUILD_USER='builduser'
[ -z "${WGET_TIMEOUT}" ] && WGET_TIMEOUT=80
[ -z "${BLOCKCHAINNETWORK}" ] && BLOCKCHAINNETWORK='mainnet'
[ -z "${LISTENPORT}" ] && LISTENPORT='3000'
[ -z "${INSTALLRDP}" ] && INSTALLRDP='N'
[ -z "${MY_SUBNET}" ] && MY_SUBNET=$(ifconfig eth0 | awk '/netmask/ { split($4,a,":"); print $2 "/" a[1] }')  # With a Pi, you get just one RJ45 jack
[ -z "${MY_SUBNET}" ] && MY_SUBNET=$(ifconfig eth0 | awk '/inet6/ { split($4,a,":"); print $2 "/" a[1] }')
[ -z "${INSTALL_USER}" ] && INSTALL_USER='cardano'
[ -z "${SUDO}" ] && SUDO='Y'
[ -z "$LIBSODIUM_VERSION" ] && LIBSODIUM_VERSION='66f017f1'
[ "${SUDO}" = 'Y' ] && sudo="sudo" || sudo=""
[ "${SUDO}" = 'Y' ] && [ $(id -u) -eq 0 ] && echo -e "Running script as root (better to use 'sudo')..."
INSTALLDIR="/home/${INSTALL_USER}"
BUILDDIR="/home/${BUILD_USER}/Cardano-BuildDir"
BUILDLOG="$BUILDDIR/build-log-$(date '+%Y-%m-%d-%H:%M:%S').log"
CARDANO_DBDIR="${INSTALLDIR}/db"
CARDANO_FILEDIR="${INSTALLDIR}/files"
CARDANO_SCRIPTDIR="${INSTALLDIR}/scripts"
[ -z "${NODE_CONFIG_FILE}" ] && NODE_CONFIG_FILE="$CARDANO_FILEDIR/${BLOCKCHAINNETWORK}-config.json"

echo "The latest version of this script lives here:  https://raw.githubusercontent.com/rgoerwit/pi-cardano-node-setup/main/scripts/pi-cardano-node-setup.sh"
echo "INSTALLDIR is '/home/${INSTALL_USER}'"
echo "BUILDDIR is '/home/${BUILD_USER}/Cardano-BuildDir'"
echo "CARDANO_FILEDIR is '${INSTALLDIR}/files'"

if [ -z "${HIDDEN_WIFI_INFO}" ]; then
	: do nothing, all good
else
	HIDDENWIFI=$(echo "$HIDDEN_WIFI_INFO" | echo "a:x" | awk -F: '{ print $1 }')
	HIDDENWIFIPASSWORD=$(echo "$HIDDEN_WIFI_INFO" | echo "a:x" | awk -F: '{ print $2 }')
	[ -z "${HIDDENWIFI}" ] && [ -z "${HIDDENWIFIPASSWORD}" ] && err_exit 45 "$0: Please supply a WPA WiFi NetworkID:Password (or omit the -h argument for no WiFi)"
fi

GUILDREPO="https://github.com/cardano-community/guild-operators"
GUILDREPO_RAW="https://raw.githubusercontent.com/cardano-community/guild-operators"
GUILDREPO_RAW_URL="${GUILDREPO_RAW}/master"
WPA_SUPPLICANT="/etc/wpa_supplicant/wpa_supplicant.conf"
WGET="wget --quiet --retry-connrefused --waitretry=10 --read-timeout=20 --timeout $WGET_TIMEOUT -t 5"
GHCVERSION="8.10.4"
GHCARCHITECTURE="$(arch)"    # could potentially be aarch64, arm7, arm8, etc. for example; see http://downloads.haskell.org/~ghc/
GCCMARMARG=""                # will be -marm for Raspberry Pi OS 32 bit; blank for Ubuntu 64
GCCARCHARG="-march=Armv8-A"  # will be -march=armv7-a for Raspberry Pi OS 32 bit; -march=Armv8-A for Ubuntu 64
GHCOS="deb10"                # could potentially be deb10, for example; see http://downloads.haskell.org/~ghc/
CABALARCHITECTURE="$(arch)"  # raspberry pi OS 32-bit is armv7l; ubuntu 64 is aarch64 See http://home.smart-cactus.org/~ben/ghc/
CABAL="$INSTALLDIR/cabal"
MAKE='make'
CABAL_OS="linux"              # will be deb10 for pi OS 32-bit, and linux for Ubuntu 64
CARDANONODEVERSION="1.25.1"
PIVERSION=$(cat /proc/cpuinfo | egrep '^Model' | sed 's/^Model\s*:\s*//i')
PIP="pip$(apt-cache pkgnames | egrep '^python[2-9]*$' | sort | tail -1 | tail -c 2 |  tr -d '[:space:]')"; 
if [ ".$SKIP_RECOMPILE" = '.Y' ]; then
    MAKE='echo "Skipping: make '
    CABAL='echo "Skipping: cabal '
fi    	

# Change default startup user to match OS; usually oldest home is the user we want
PIUSER=$(ls -c /home | head -1 | tr '[:upper:]' '[:lower:]')
# Use ubuntu for ubuntu, pi for Raspberry Pi OS
if egrep -iq Ubuntu "/etc/issue"; then
    export PIUSER="ubuntu"
fi

# Make sure our build user exists and belongs to all the good groups
#
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

mkdir "$BUILDDIR" 2> /dev/null
chown "${BUILD_USER}.${BUILD_USER}" "$BUILDDIR"
chmod 2755 "$BUILDDIR"
touch "$BUILDLOG"
echo "Logging; run 'tail -f \"$BUILDLOG\"' in another window to monitor"

# Update system, install prerequisites, utilities, etc.
#
$APTINSTALLER update        1>> "$BUILDLOG"
$APTINSTALLER upgrade       1>> "$BUILDLOG"
$APTINSTALLER dist-upgrade  1>> "$BUILDLOG"
# Install a bunch of necessary development and support packages
$APTINSTALLER install aptitude autoconf automake bc bsdmainutils build-essential curl dialog emacs g++ git git gnupg \
	gparted htop iproute2 jq libffi-dev libgmp-dev libncursesw5 libpq-dev libsodium-dev libssl-dev libsystemd-dev \
	libtinfo-dev libtool libudev-dev libusb-1.0-0-dev make moreutils pkg-config python3 python3 python3-pip \
	librocksdb-dev rocksdb-tools rsync secure-delete sqlite sqlite3 systemd tcptraceroute tmux zlib1g-dev \
	libbz2-dev liblz4-dev libsnappy-dev cython libnuma-dev 1>> "$BUILDLOG" 2>&1 \
	    || err_exit 71 "$0: Failed to install apt-get dependencies; aborting"
				
# Make sure some other basic prerequisites are correctly installed
$APTINSTALLER install --reinstall build-essential 1>> "$BUILDLOG" 2>&1
$APTINSTALLER install --reinstall gcc             1>> "$BUILDLOG" 2>&1
dpkg-reconfigure build-essential                  1>> "$BUILDLOG" 2>&1
dpkg-reconfigure gcc                              1>> "$BUILDLOG" 2>&1
$APTINSTALLER install llvm-9                      1>> "$BUILDLOG" 2>&1 || err_exit 71 "$0: Failed to install llvm-9; aborting"
$APTINSTALLER install rpi-imager                  1>> "$BUILDLOG" 2>&1  # Might not be present, and if so, no biggie
$APTINSTALLER install rpi-eeprom                  1>> "$BUILDLOG" 2>&1  # Might not be present, and if so, no biggie

if [ -x $(which rpi-eeprom-update) ]; then 
	if rpi-eeprom-update | egrep -q 'BOOTLOADER: *up-to-date'; then
		: do nothing
	else
		rpi-eeprom-update -a 1>> "$BUILDLOG" 2>&1
    fi
fi

$APTINSTALLER install net-tools openssh-server    1>> "$BUILDLOG" 2>&1
systemctl enable ssh                              1>> "$BUILDLOG" 2>&1
service ssh start                                 1>> "$BUILDLOG" 2>&1 \
	err_exit 18 "$0: Can't start ssh subsystem ('service ssh start'); aborting"

if [ ".$OVERCLOCK_SPEED" != '.' ]; then
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
			echo "Overclocking already set up; skipping (edit $BOOTCONFIG file to change settings)"
		else
		    [[ "$OVERCLOCK_SPEED" = [0-9]* ]] || err_exit 19 "$0: For argument -o <speed>, <speed> must be an integer (e.g., 2100); aborting"
			echo "Current CPU temp:  `vcgencmd measure_temp`"
			echo "Current Max CPU speed:  `cat /sys/devices/system/cpu/cpu0/cpufreq/cpuinfo_max_freq`"
			echo "Setting speed to $OVERCLOCK_SPEED; please check $BOOTCONFIG file before next restart"
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
if [ ".$DONT_OVERWRITE" != 'Y' ] || [ ".$LISTENPORT" != '.' ]; then
	ufw --force reset            1>> "$BUILDLOG" 2>&1
	if apt-cache pkgnames | egrep -q '^ufw$'; then
		ufw disable 1>> "$BUILDLOG" # install ufw if not present
	else
		$APTINSTALLER install ufw 1>> "$BUILDLOG" 2>&1
	fi
	# echo "Installing firewall with only ports 22, 3000, 3001, and 3389 open..."
	ufw default deny incoming    1>> "$BUILDLOG" 2>&1
	ufw default allow outgoing   1>> "$BUILDLOG" 2>&1
	ufw allow ssh                1>> "$BUILDLOG" 2>&1
	ufw allow "$LISTENPORT/tcp"  1>> "$BUILDLOG" 2>&1
	# ufw allow 3001/tcp           1>> "$BUILDLOG"
	# ufw allow 6000/tcp           1>> "$BUILDLOG"
	# ufw deny from [IP.address] to any port [number]
	# ufw delete [rule_number]
	ufw --force enable           1>> "$BUILDLOG" 2>&1
	# ufw status numbered  # show what's going on

	# Add RDP service if INSTALLRDP is Y
	#
	if [ ".$INSTALLRDP" = ".Y" ]; then
		$APTINSTALLER install xrdp     1>> "$BUILDLOG" 2>&1
		$APTINSTALLER install tasksel  1>> "$BUILDLOG" 2>&1
		tasksel install ubuntu-desktop 1>> "$BUILDLOG" 2>&1
		systemctl enable xrdp          1>> "$BUILDLOG" 2>&1
		RUID=$(who | awk 'FNR == 1 {print $1}')
		RUSER_UID=$(id -u ${RUID})
		sudo -u "${RUID}" DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/${RUSER_UID}/bus" gsettings set org.gnome.settings-daemon.plugins.power sleep-inactive-battery-type 'nothing' 2>> "$BUILDLOG"
		sudo -u "${RUID}" DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/${RUSER_UID}/bus" gsettings set org.gnome.settings-daemon.plugins.power sleep-inactive-ac-type 'nothing'      2>> "$BUILDLOG"
		dconf update 2>> "$BUILDLOG"
		sudo systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target 1>> "$BUILDLOG" 2>&1
		ufw allow from "$MY_SUBNET" to any port 3389 1>> "$BUILDLOG" 2>&1
	fi
fi

# Add hidden WiFi network if -h <network SSID> was supplied; I don't recommend WiFi except for setup
#
if [ ".$HIDDENWIFI" != '.' ]; then
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
	systemctl restart wpa_supplicant.service  1>> "$BUILDLOG"
	# renew DHCP leases
	dhclient "$WLAN" 1>> "$BUILDLOG" 2>&1
fi

# Add cardano user (or whatever install user is used) and lock password
#
id "$INSTALL_USER" 1>> "$BUILDLOG"  2>&1 \
    || useradd -m -s /bin/bash "$INSTALL_USER" 1>> "$BUILDLOG"
# The account for the install user (which will run cardano-node) should be locked
passwd -l "$INSTALL_USER"                   1>> "$BUILDLOG"
usermod -a -G users "$INSTALL_USER"         1>> "$BUILDLOG" 2>&1

#
# Install GHC, cabal
#
cd "$BUILDDIR"
$WGET "http://downloads.haskell.org/~ghc/${GHCVERSION}/ghc-${GHCVERSION}-${GHCARCHITECTURE}-${GHCOS}-linux.tar.xz" -O "ghc-${GHCVERSION}-${GHCARCHITECTURE}-${GHCOS}-linux.tar.xz"
if [ ".$SKIP_RECOMPILE" != '.Y' ]; then
	'rm' -rf "ghc-${GHCVERSION}"
	tar -xf "ghc-${GHCVERSION}-${GHCARCHITECTURE}-${GHCOS}-linux.tar.xz" 1>> "$BUILDLOG"
	cd "ghc-${GHCVERSION}"
	./configure CONF_CC_OPTS_STAGE2="$GCCMARMARG $GCCARCHARG" CFLAGS="$GCCMARMARG $GCCARCHARG" 1>> "$BUILDLOG"
fi
$MAKE install 1>> "$BUILDLOG"
#
cd "$BUILDDIR"
$WGET "http://home.smart-cactus.org/~ben/ghc/cabal-install-3.4.0.0-rc4-${CABALARCHITECTURE}-${CABAL_OS}.tar.xz" -O "cabal-install-3.4.0.0-rc4-${CABALARCHITECTURE}-${CABAL_OS}.tar.xz" || \
    err_exit 48 "$0: Unable to download cabal; aborting"
tar -xf "cabal-install-3.4.0.0-rc4-${CABALARCHITECTURE}-${CABAL_OS}.tar.xz" 1>> "$BUILDLOG"
cp cabal "$CABAL"             || err_exit 66 "$0: Failed to copy cabal into position ($CABAL); aborting"
chown root.root "$CABAL"
chmod 755 "$CABAL"
$CABAL update 1>> "$BUILDLOG" || err_exit 67 "$0: Failed to '$CABAL update'; aborting"

# Install wacky Cardano version of libsodium
#
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

#
NODE_BUILD_NUM=$($WGET -S -O- 'https://hydra.iohk.io/job/Cardano/cardano-node/cardano-deployment/latest-finished/download/1/index.html' 2>&1 | sed -n '/^ *[lL]ocation: / { s|^.*/build/\([^/]*\)/download.*$|\1|ip; q; }')
[ -z "$NODE_BUILD_NUM" ] && \
    (NODE_BUILD_NUM=$($WGET -S -O- "https://hydra.iohk.io/job/Cardano/iohk-nix/cardano-deployment/latest-finished/download/1/${BLOCKCHAINNETWORK}-byron-genesis.json" 2>&1 | sed -n '/^ *[lL]ocation: / { s|^.*/build/\([^/]*\)/download.*$|\1|ip; q; }') || \
		err_exit 49 "$0:  Unable to fetch node build number; aborting")
echo "$0:  NODE_BUILD_NUM discovered:  $NODE_BUILD_NUM" 1>> "$BUILDLOG" 2>&1
for bashrcfile in "$HOME/.bashrc" "/home/${BUILD_USER}/.bashrc" "$INSTALLDIR/.bashrc"; do
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
		    echo "Substituting in $bashrcfile:  export ${envvar}=.*$ -> export ${envvar}=${SUBSTITUTION}" 1>> $BUILDLOG 2>&1
			sed -i "$bashrcfile" -e "s|^ *export +\(${envvar}\)=.*$\+|export \1=${SUBSTITUTION}|g"
		else
		    echo "Appending to $bashrcfile: ${envvar}=${SUBSTITUTION}" 1>> $BUILDLOG 2>&1
			echo "export ${envvar}=${SUBSTITUTION}" >> $bashrcfile
		fi
    done
done
. "/home/${BUILD_USER}/.bashrc"

# Install cardano-node
#
# BACKUP PREVIOUS SOURCES AND DOWNLOAD 1.25.1
#
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
echo "package cardano-crypto-praos" >  cabal.project.local
echo "  flags: -external-libsodium-vrf" >>  cabal.project.local
echo -e "package cardano-crypto-praos\n flags: -external-libsodium-vrf" > cabal.project.local
#
# BUILD
#
$CABAL build cardano-cli cardano-node 1>> "$BUILDLOG" 2>&1 || err_exit 87 "$0: Failed to build cardano-cli and cardano-node; aborting"
#
# STOP THE NODE TO BE ABLE TO REPLACE BINARIES
#
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
$CABAL install --installdir "$INSTALLDIR" cardano-cli cardano-node 1>> "$BUILDLOG"
if [ ".$SKIP_RECOMPILE" != '.Y' ]; then
	[ -L "$INSTALLDIR/cardano-cli" ] && rm -f "$INSTALLDIR/cardano-cli"
	[ -L "$INSTALLDIR/cardano-node" ] && rm -f "$INSTALLDIR/cardano-node"
fi
if [ -x "$INSTALLDIR/cardano-cli" ]; then
    : do nothing
else
    cp $(find "$BUILDDIR/cardano-node" -type f -name cardano-cli ! -path '*OLD*') "$INSTALLDIR/cardano-cli"
    cp $(find "$BUILDDIR/cardano-node" -type f -name cardano-node ! -path '*OLD*') "$INSTALLDIR/cardano-node"
    # cp $(find "$HOME/git/cardano-node/dist-newstyle/build" -type f -name "cardano-cli") "$INSTALLDIR/cardano-cli"
    # cp $(find "$HOME/git/cardano-node/dist-newstyle/build" -type f -name "cardano-node") "$INSTALLDIR/cardano-node"
fi
echo "Installed cardano-node version: $(${INSTALLDIR}/cardano-node version | head -1)"
echo "Installed cardano-cli version: $(${INSTALLDIR}/cardano-cli version | head -1)"

# Set up directory structure in the $INSTALLDIR (OK if they exist already)
for subdir in 'files' 'db' 'guild-db' 'logs' 'scripts' 'sockets' 'priv' 'pkgconfig'; do
    mkdir -p "${INSTALLDIR}/$subdir"
    chown -R "${INSTALL_USER}.${INSTALL_USER}" "${INSTALLDIR}/$subdir" 2>/dev/null
	find "${INSTALLDIR}/$subdir" -type d -exec chmod "2775" {} \;
	find "${INSTALLDIR}/$subdir" -type f -exec chmod "0664" {} \;
done

#
# UPDATE mainnet-config.json TO THE LATEST VERSION AND START THE NODE
#
if [ ".$DONT_OVERWRITE" != '.Y' ]; then
	cd "$INSTALLDIR"
	echo "Saving the configuration of the EKG port, PROMETHEUS port, and listening address (if there are any)" 1>> "$BUILDLOG"
	export CURRENT_EKG_PORT=$(jq -r .hasEKG "${CARDANO_FILEDIR}/${BLOCKCHAINNETWORK}-config.json")
	export CURRENT_PROMETHEUS_PORT=$(jq -r .hasPrometheus[1] "${CARDANO_FILEDIR}/${BLOCKCHAINNETWORK}-config.json")
	export CURRENT_PROMETHEUS_LISTEN=$(jq -r .hasPrometheus[0] "${CARDANO_FILEDIR}/${BLOCKCHAINNETWORK}-config.json")
	echo "Fetching json files from IOHK; starting with: https://hydra.iohk.io/build/${NODE_BUILD_NUM}/download/1/${BLOCKCHAINNETWORK}-config.json " 1>> "$BUILDLOG"
	$WGET "https://hydra.iohk.io/build/${NODE_BUILD_NUM}/download/1/${BLOCKCHAINNETWORK}-config.json"          -O "${CARDANO_FILEDIR}/${BLOCKCHAINNETWORK}-config.json"
	$WGET "https://hydra.iohk.io/build/${NODE_BUILD_NUM}/download/1/${BLOCKCHAINNETWORK}-topology.json"        -O "${CARDANO_FILEDIR}/${BLOCKCHAINNETWORK}-topology.json"
	$WGET "https://hydra.iohk.io/build/${NODE_BUILD_NUM}/download/1/${BLOCKCHAINNETWORK}-byron-genesis.json"   -O "${CARDANO_FILEDIR}/${BLOCKCHAINNETWORK}-byron-genesis.json"
	$WGET "https://hydra.iohk.io/build/${NODE_BUILD_NUM}/download/1/${BLOCKCHAINNETWORK}-shelley-genesis.json" -O "${CARDANO_FILEDIR}/${BLOCKCHAINNETWORK}-shelley-genesis.json"
	sed -i "${CARDANO_FILEDIR}/${BLOCKCHAINNETWORK}-config.json" -e "s/TraceBlockFetchDecisions\": false/TraceBlockFetchDecisions\": true/g"
	# Restoring previous parameters to the config file:
	if [ ".$CURRENT_EKG_PORT" != '.' ] && egrep -q 'CURRENT_EKG_PORT' "${BLOCKCHAINNETWORK}-config.json"; then 
		jq .hasEKG="${CURRENT_EKG_PORT}"                         "${CARDANO_FILEDIR}/${BLOCKCHAINNETWORK}-config.json" |  sponge "$CARDANO_FILEDIR/${BLOCKCHAINNETWORK}-config.json" 
		jq .hasPrometheus[0]="\"${CURRENT_PROMETHEUS_LISTEN}\""  "${CARDANO_FILEDIR}/${BLOCKCHAINNETWORK}-config.json" |  sponge "$CARDANO_FILEDIR/${BLOCKCHAINNETWORK}-config.json" 
		jq .hasPrometheus[1]="${CURRENT_PROMETHEUS_PORT}"        "${CARDANO_FILEDIR}/${BLOCKCHAINNETWORK}-config.json" |  sponge "$CARDANO_FILEDIR/${BLOCKCHAINNETWORK}-config.json" 
	fi
	sed -i "$CARDANO_FILEDIR/${BLOCKCHAINNETWORK}-config.json" -e "s/TraceBlockFetchDecisions\": +false/TraceBlockFetchDecisions\": true/g"
	[ -s "$CARDANO_FILEDIR/${BLOCKCHAINNETWORK}-config.json" ] || err_exit 58 "0: Failed to download ${BLOCKCHAINNETWORK}-config.json from https://hydra.iohk.io/build/${NODE_BUILD_NUM}/download/1/"

	# Set up startup script
	#
	SYSTEMSTARTUPSCRIPT="/lib/systemd/system/cardano-node.service"
	echo "(Re-)creating $SYSTEMSTARTUPSCRIPT" 1>> "$BUILDLOG"
	[ -f "$NODE_CONFIG_FILE" ] || err_exit 28 "$0: Can't find config.yaml file, "$NODE_CONFIG_FILE"; aborting"
	#
	#Usage: cardano-node run [--topology FILEPATH] [--database-path FILEPATH]
	#                        [--socket-path FILEPATH]
	#                        [--byron-delegation-certificate FILEPATH]
	#                        [--byron-signing-key FILEPATH]
	#                        [--shelley-kes-key FILEPATH]
	#                        [--shelley-vrf-key FILEPATH]
	#                        [--shelley-operational-certificate FILEPATH]
	#                        [--host-addr IPV4-ADDRESS]
	#                        [--host-ipv6-addr IPV6-ADDRESS]
	#                        [--port PORT]
	#                        [--config NODE-CONFIGURATION] [--validate-db]
	#
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
ExecStart=$INSTALLDIR/cardano-node run --socket-path $INSTALLDIR/sockets/core-node.socket --config $NODE_CONFIG_FILE $IPV4ARG $IPV6ARG --port $LISTENPORT --topology $CARDANO_FILEDIR/${BLOCKCHAINNETWORK}-topology.json --database-path ${CARDANO_DBDIR}/
Restart=on-failure
RestartSec=12s
LimitNOFILE=32768
 
[Install]
WantedBy=multi-user.target

_EOF
	chown root.root "$SYSTEMSTARTUPSCRIPT"
	chmod 0644 "$SYSTEMSTARTUPSCRIPT"
fi
echo "Cardano node will be started as follows:  $INSTALLDIR/cardano-node run --socket-path $INSTALLDIR/sockets/core-node.socket --config $NODE_CONFIG_FILE $IPV4ARG $IPV6ARG --port $LISTENPORT --topology $CARDANO_FILEDIR/${BLOCKCHAINNETWORK}-topology.json --database-path ${CARDANO_DBDIR}/"
systemctl daemon-reload	
systemctl enable cardano-node 1>> "$BUILDLOG"
systemctl start cardano-node  1>> "$BUILDLOG"

#
# UPDATE gLiveView.sh
#
cd "$INSTALLDIR"
$WGET "${GUILDREPO_RAW_URL}/scripts/cnode-helper-scripts/gLiveView.sh" -O "${CARDANO_SCRIPTDIR}/gLiveView.sh" \
    || err_exit 108 "$0: Failed to fetch ${GUILDREPO_RAW_URL}/scripts/cnode-helper-scripts/gLiveView.sh; aborting"
chmod 755 "${CARDANO_SCRIPTDIR}/gLiveView.sh"
if [ ".$DONT_OVERWRITE" != '.Y' ]; then
	$WGET "${GUILDREPO_RAW_URL}/scripts/cnode-helper-scripts/env" -O "${CARDANO_SCRIPTDIR}/env" \
		|| err_exit 109 "$0: Failed to fetch ${CARDANO_SCRIPTDIR}/scripts/cnode-helper-scripts/env; aborting"
	echo "Setting config file in gLiveView script: ^\#* *CONFIG=\"\${CNODE_HOME}/files/config.json -> CONFIG=\"$NODE_CONFIG_FILE\""                  1>> $BUILDLOG 2>&1
	echo "Setting socket in gLiveView script: ^\#* *SOCKET=\"\${CNODE_HOME}/sockets/node0.socket -> SOCKET=\"$INSTALLDIR/sockets/core-node.socket\"" 1>> $BUILDLOG 2>&1
	sed -i "${CARDANO_SCRIPTDIR}/env" \
		-e "s|^\#* *CONFIG=\"\${CNODE_HOME}/files/config.json\"|CONFIG=\"$NODE_CONFIG_FILE\"|g" \
		-e "s|^\#* *SOCKET=\"\${CNODE_HOME}/sockets/node0.socket\"|SOCKET=\"$INSTALLDIR/sockets/core-node.socket\"|g" \
			|| err_exit 109 "$0: Failed to modify gLiveView 'env' file, ${CARDANO_SCRIPTDIR}/env; aborting"
fi

# install other utilities
#
$PIP install --upgrade pip   1>> "$BUILDLOG" 2>&1
$PIP install pip-tools       1>> "$BUILDLOG" 2>&1
$PIP install python-cardano  1>> "$BUILDLOG" 2>&1
$PIP install cardano-tools   1>> "$BUILDLOG" \
    || err_exit 117 "$0: Unable to install cardano tools:  $PIP install cardano-tools; aborting"

echo "Tasks:"
echo "  It may be necessary to clear the db-folder (${CARDANO_DBDIR}) before running cardano-node again"
echo "  It is highly recommended that the (powerful) $PIUSER account be locked or otherwise secured"
(date | egrep UTC) \
    || echo "  Please set the timezone (e.g., timedatectl set-timezone 'America/Chicago')"

rm -f "$TEMPLOCKFILE" 2> /dev/null
rm -f "$TMPFILE"      2> /dev/null
rm -f "$LOGFILE"      2> /dev/null


