#!/bin/bash

set -e
set -u
set -o pipefail

if [[ ! -f /etc/debian_version ]]; then
  echo "minideb can currently only be built on debian based distros, aborting..."
  exit 1
fi

apt-get update
apt-get install -y debootstrap debian-archive-keyring jq dpkg-dev gnupg apt-transport-https ca-certificates curl gpg perl

cd /dev/shm/ && wget https://ftp.debian.org/debian/pool/main/d/debian-archive-keyring/debian-archive-keyring_2025.1_all.deb && dpkg -i debian-archive*.deb
