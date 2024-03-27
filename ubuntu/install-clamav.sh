#!/usr/bin/env bash

# run as root
if (( $EUID != 0 )); then
   echo "this script should be running as root identity"
   exit
fi

apt-get update && \
    apt-get install cron clamav clamav-daemon -y

systemctl enable clamav-daemon
systemctl enable clamav-freshclam

mkdir /var/log/antivirus

# setup crontab job for automatic scanning daily and email reports
crontab -l > mycron
echo "03 3 * * * /usr/bin/clamscan -ri --no-summary / 2&1 >> /var/log/antivirus/antivus.log" >> mycron
crontab mycron
rm mycron
