#!/usr/bin/env bash

# run as root
if (( $EUID != 0 )); then
   echo "this script should be running as root identity"
   exit
fi

apt-get update && \
    apt-get install slim ubuntu-desktop -y

echo "after finished, reboot the machine and check /tmp/.X11-unix"


