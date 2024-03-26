#!/usr/bin/env bash

# run as root
if (( $EUID != 0 )); then
   echo "this script should be running as root identity"
   exit
fi

if [ -z "$1" ]
  then
    echo "require notification email"
    exit
fi

apt-get update && \
    apt-get install cron clamav clamav-daemon -y

systemctl enable clamav-daemon
systemctl enable clamav-freshclam

# setup crontab job for automatic scanning daily and email reports
crontab -l > mycron
echo "MAILTO=$1" >> mycron
echo "03 3 * * * /usr/bin/clamscan -ri --no-summary /" >> mycron
crontab mycron
rm mycron
