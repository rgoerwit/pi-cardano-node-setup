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
#  Used to detect failure of a cardano block-producing node, and a restart
#  of the current node as a block producer.
#
#  Assumes block producer kes-key, vrf-key, and operational-certificate
#  information are available in the /etc/systemd/system/cardano-node.service
#  start-up file (commented out, except when this node is producing blocks).
#
###############################################################################

PARENTADDR="000.000.000.000"
PARENTPORT="3000"
LOGGER="logger -i 'cardano-heartbeat-failover'"

jump_ship () { 
	EXITCODE=$1; shift
    PRIORITY=$1; shift
	$LOGGER -p ${PRIORITY:-user.info} "$*"
	exit $EXITCODE 
}

# If we are actually the parent, exit
#
for LOCALADDR in $(ip addr show | egrep '^[     ]*inet6?[       ]*' | awk '{ print $2 }' | sed 's|/[0-9.]*$||' | sort -u); do
    [ ".$LOCALADDR" = ".$PARENTADDR" ] \
        && exit 0
done
#
[ -z "${EXTERNAL_IPV4_ADDRESS}" ] && EXTERNAL_IPV4_ADDRESS="$(dig +timeout=2 +short myip.opendns.com @resolver1.opendns.com 2> /dev/null | egrep -v '^;;' | tr -d '\r\n ')" 2> /dev/null
[ -z "${EXTERNAL_IPV6_ADDRESS}" ] && EXTERNAL_IPV6_ADDRESS="$(dig +timeout=2 +short -6 myip.opendns.com aaaa @resolver1.ipv6-sandbox.opendns.com 2> /dev/null | egrep -v '^;;' | tr -d '\r\n ')" 2> /dev/null
[ -z "${EXTERNAL_IPV4_ADDRESS}" ] && EXTERNAL_IPV4_ADDRESS="$(host -W 1 -4 myip.opendns.com resolver1.opendns.com 2> /dev/null | tail -1 | awk '{ print $(NF) }')" 2> /dev/null
[ -z "${EXTERNAL_IPV6_ADDRESS}" ] && EXTERNAL_IPV6_ADDRESS="$(host -W 1 -6 myip.opendns.com resolver1.opendns.com 2> /dev/null | tail -1 | awk '{ print $(NF) }')" 2> /dev/null
if [ ".$EXTERNAL_IPV4_ADDRESS" = ".$PARENTADDR" ] || [ ".$EXTERNAL_IPV6_ADDRESS" = ".$PARENTADDR" ]; then
    exit 0
fi
if [ -z "$EXTERNAL_IPV4_ADDRESS" ] && [ -z "$EXTERNAL_IPV6_ADDRESS" ]; then
    jump_ship 10 user.crit "Can't determine external IP address; heartbeat check failure (network down?)"
fi

# If we get to here, we are not the parent
#
[ -f "/lib/systemd/system/cardano-node.service" ] && SYSTEMSTARTUPSCRIPT="/lib/systemd/system/cardano-node.service"
[ -f "/etc/systemd/system/cardano-node.service" ] && SYSTEMSTARTUPSCRIPT="/etc/systemd/system/cardano-node.service"

if nmap -Pn -p "$PARENTPORT" -sT "$PARENTADDR" 2> /dev/null | egrep -q "^ *$PARENTPORT/.*open"
then
    # Parent is OK.  If we're not running as a block producer, we can exit.
    egrep -q '^[ \t]*ExecStart.*#' "$SYSTEMSTARTUPSCRIPT" \
        || jump_ship 1 user.warn "Failover stand-down blocked; node start script lacks commented-out block-producer arguments: $SYSTEMSTARTUPSCRIPT"
    egrep -q 'kes-key\|vrf-key\|operational-certificate' "$SYSTEMSTARTUPSCRIPT" \
        || jump_ship 2 user.warn "Node is configured a relay, not a failover spare; not modifying $SYSTEMSTARTUPSCRIPT"

    # Parent is OK (again), make us just a node; comment out key-related items on cardano-node command line
    sed -i "$SYSTEMSTARTUPSCRIPT" \
        -e '/^[^#]*$/ s/^\([[:space:]]*ExecStart=.*\)[[:space:]]\(\(--[0-z]*-\(kes-key\|vrf-key\|operational-certificate\)[[:space:]]*[^[:space:]]*[[:space:]]*\)\{3\}.*\)$/\1 # \2/' \
        || jump_ship 3 user.warn "Failed to switch local cardano-node to a regular relay node; failed to edit: $SYSTEMSTARTUPSCRIPT"

    systemtcl is-active cardano-node 1> /dev/null \
        || jump_ship 4 user.warn "Holding off on cardano-node restart; service is inactive"
    systemctl reload-or-restart cardano-node \
        || jump_ship 5 user.crit "Failed to switch local cardano-node to a regular relay; can't (re)start cardano-node"
else
    # Parent node $PARENTADDR:$PARENTPORT isn't allowing TCP connects; either it's down or we're cut off from it
    egrep -q 'kes-key\|vrf-key\|operational-certificate' "$SYSTEMSTARTUPSCRIPT" \
        || jump_ship 6 user.warn "Failover blocked; node start script lacks commented-out block-producer arguments: $SYSTEMSTARTUPSCRIPT"
    egrep -q '^[ \t]*ExecStart.*#' "$SYSTEMSTARTUPSCRIPT" \
        || jump_ship 0 user.debug "Node is already a block producer; not modifying $SYSTEMSTARTUPSCRIPT"

    # Parent is down, make us a block producer; remove any commented-out portions of the cardano-node command line
    sed -i "$SYSTEMSTARTUPSCRIPT" -e '/^[[:space:]]*ExecStart/ s/ # / /' \
        || jump_ship 7 user.crit "Failover blocked; can't rewrite start-up script: $SYSTEMSTARTUPSCRIPT"

    systemtcl is-active cardano-node 1> /dev/null \
        || jump_ship 8 user.warn "Holding off on cardano-node restart; service is inactive"
    systemctl reload-or-restart cardano-node \
        || jump_ship 9 user.crit "Failed to switch local cardano-node to a block producer: Can't (re)start cardano-node"
fi

# If we get to here, we're good
exit 0
