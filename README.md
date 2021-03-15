## Synopsis

**pi-cardano-setup.sh**:  Bash script that installs a Cardano relay node on a Raspberry Pi 4 running 64-bit aarch64 Ubuntu LTS

## Code Example

Example invocations follow.

**New (overclocking) mainnet setup on TCP port 3000**:   pi-cardano-setup.sh -D -b builduser -u cardano -n mainnet -o 2100 -p 3000 

**Refresh of existing mainnet setup (keep existing config files)**:  pi-cardano-setup.sh -D -d -b builduser -u cardano -n mainnet

Command-line syntax is as follows:

```
Usage: $PROGNAME [-4 <external IPV4>] [-6 <external IPV6>] [-b <builduser>] [-c <node config filename>] [-d] [-D] \
    [-h <SID:password>] [-m <seconds>] [-n <mainnet|testnet|launchpad|guild|staging>] [-o <overclock speed>] \
	[-p <port>] [-r] [-s <subnet>] [-u <installuser>] [-w <libsodium-version-number>] [-v <VLAN num> ] [-x]
```

Argument explanation:

```
-4    External IPv4 address (defaults to 0.0.0.0)
-6    External IPv6 address (defaults to NULL)
-b    User whose home directory will be used for compiling (defaults to 'builduser')
-c    Node configuration file (defaults to <install user home dir>/<network>-config.json)
-d    Don't overwrite config files, or 'env' file for gLiveView
-D    Emit chatty debugging output about what the program is doing
-h    Install (naturally, hidden) WiFi; format:  SID:password (only use WiFi on the relay, not block producer)
-m    Maximum time in seconds that you allow the file download operation to take before aborting (Default: 80s)
-n    Connect to specified network instead of mainnet network (Default: mainnet)
      e.g.: -n testnet (alternatives: allegra launchpad mainnet mary_qa shelley_qa staging testnet...)
-o    Overclocking value (should be something like, e.g., 2100 for a Pi 4)
-p    Listen port (default 3000)
-r    Install RDP
-s    Networks to allow SSH from (comma-separated, CIDR)
-u    User who will run the executables and in whose home directory the executables will be installed
-w    Specify a libsodium version (defaults to the wacky version the Cardano project recommends)
-v    Enable vlan <number> on eth0; DHCP to that VLAN; disable eth0 interface
-x    Don't recompile anything big, like ghc, libsodium, and cardano-node
```

## Motivation

This script solves a practical problem.

ARM processor-based systems are not well supported in the Cardano world, and the Pi 4 is in particular not well supported.

pi-cardano-setup.sh not only gets the operating system ready, installing all the basic prereqs, but it also actually builds and configures a generic Cardano node.

It is a distillation of many sets of available directions, including:

>     https://docs.cardano.org/projects/cardano-node/en/latest/
>     https://cardano-node-installation.stakepool247.eu/cardano-node-upgrades/upgrade-to-1.25.1
>	https://www.haskell.org/ghc/blog/20200515-ghc-on-arm.html
>	https://www.coincashew.com/coins/overview-ada/guide-how-to-build-a-haskell-stakepool-node

## Installation

Simply copy pi-cardano-setup.sh (and optionally pi-cardano-fake-code.sh) onto a fresh Pi 4 running 64-bit aarch64 Ubuntu LTS and execute it.

It may be run subsequently with the -d argument to refresh executables, but leave configuration files untouched.

## Tests

There are no regression tests for this script.  Please do not run it on an already-configured relay that's been lovingly hand crafted and configured.  It may overwrite your work if you're not careful.

This script is intended for situations where you want a generic, working relay up fast.  ("Fast" by Pi standards, that is.)

## Contributors

Please email the author at achaar@goerwitz.com if you have suggestions or want to help out.

## License

MIT license - (c) Richard Goerwitz 2021 - use at your own risk

