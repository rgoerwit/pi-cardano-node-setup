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
###############################################################################


# If we are actually the parent, exit
#
for LOCALADDR in $(ip addr show | egrep '^[     ]*inet6?[       ]*' | awk '{ print $2 }' | sed 's|/[0-9.]*$||' | sort -u); do
    [ ".$LOCALADDR" = ".$PARENTADDR" ] \
        && exit 0
done
#
[ -z "${EXTERNAL_IPV4_ADDRESS}" ] && EXTERNAL_IPV4_ADDRESS="$(dig +timeout=3 +short myip.opendns.com @resolver1.opendns.com 2> /dev/null | egrep -v '^;;' | tr -d '\r\n ')" 2> /dev/null
[ -z "${EXTERNAL_IPV6_ADDRESS}" ] && EXTERNAL_IPV6_ADDRESS="$(dig +timeout=3 +short -6 myip.opendns.com aaaa @resolver1.ipv6-sandbox.opendns.com 2> /dev/null | egrep -v '^;;' | tr -d '\r\n ')" 2> /dev/null
[ -z "${EXTERNAL_IPV4_ADDRESS}" ] && EXTERNAL_IPV4_ADDRESS="$(host -4 myip.opendns.com resolver1.opendns.com 2> /dev/null | tail -1 | awk '{ print $(NF) }')" 2> /dev/null
[ -z "${EXTERNAL_IPV6_ADDRESS}" ] && EXTERNAL_IPV6_ADDRESS="$(host -6 myip.opendns.com resolver1.opendns.com 2> /dev/null | tail -1 | awk '{ print $(NF) }')" 2> /dev/null
if [ ".$EXTERNAL_IPV4_ADDRESS" = ".$PARENTADDR" ] || [ ".$EXTERNAL_IPV6_ADDRESS" = ".$PARENTADDR" ]; then
    exit 0
fi

# If we get to here, we are not the parent
#
[ -f "/lib/systemd/system/cardano-node.service"] && SYSTEMSTARTUPSCRIPT="/lib/systemd/system/cardano-node.service"
[ -f "/etc/systemd/system/cardano-node.service"] && SYSTEMSTARTUPSCRIPT="/etc/systemd/system/cardano-node.service"

# Parent is down, make us a block producer
sed -i \
    -e '/^[^#]*$/ s/^\([[:space:]]*ExecStart=.*\)[[:space:]]\(\(--[0-z]*-\(kes-key\|vrf-key\|operational-certificate\)[[:space:]]*[^[:space:]]*[[:space:]]*\)\{3\}.*\)$/\1 # \2/' \
    "$SYSTEMSTARTUPSCRIPT"

# Parent is OK (again), make us just a node
sed -i \
    -e '/^[[:space:]]*ExecStart/ s/ # / /' \
    "$SYSTEMSTARTUPSCRIPT"

if systemtcl is-active cardano-node 1> /dev/null; then
    systemctl reload-or-restart cardano-node
fi
