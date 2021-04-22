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


[ -z "${EXTERNAL_IPV4_ADDRESS}" ] && EXTERNAL_IPV4_ADDRESS="$(dig +timeout=5 +short myip.opendns.com @resolver1.opendns.com 2> /dev/null | egrep -v '^;;' | tr -d '\r\n ')" 2> /dev/null
[ -z "${EXTERNAL_IPV4_ADDRESS}" ] && EXTERNAL_IPV4_ADDRESS="$(host -4 myip.opendns.com resolver1.opendns.com 2> /dev/null | tail -1 | awk '{ print $(NF) }')" 2> /dev/null
[ -z "${EXTERNAL_IPV6_ADDRESS}" ] && EXTERNAL_IPV6_ADDRESS="$(dig +timeout=5 +short -6 myip.opendns.com aaaa @resolver1.ipv6-sandbox.opendns.com 2> /dev/null | egrep -v '^;;' | tr -d '\r\n ')" 2> /dev/null
[ -z "${EXTERNAL_IPV6_ADDRESS}" ] && EXTERNAL_IPV6_ADDRESS="$(host -6 myip.opendns.com resolver1.opendns.com 2> /dev/null | tail -1 | awk '{ print $(NF) }')" 2> /dev/null

# If I am actually the parent, exit
for LOCALADDR in $(ip addr show | egrep '^[     ]*inet6?[       ]*' | awk '{ print $2 }' | sed 's|/[0-9.]*$||' | sort -u); do
    if [ ".$LOCALADDR" = ".$PARENTADDR" ]; then
        (systemctl status cardano-node | egrep -qi 'inactive.*dead') && exit 0
        (systemctl status cardano-node | egrep -qi 'active.*unning') && exit 0
        systemctl restart cardano-node
    fi
done


sed -i
-e "s@^#* *NO_INTERNET_MODE=['\"]*N['\"]*@NO_INTERNET_MODE=\"\${NO_INTERNET_MODE:-Y}\"@" \
