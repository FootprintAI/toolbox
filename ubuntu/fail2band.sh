#!/usr/bin/env bash

# run as root
if (( $EUID != 0 )); then
   echo "this script should be running as root identity"
   exit
fi

apt-get install -y fail2ban rsyslog

# copy configures
cp /etc/fail2ban/fail2ban.conf /etc/fail2ban/fail2ban.local
cp /etc/fail2ban/jail.conf /etc/fail2ban/jail.local

# check services 
systemctl status fail2ban

### check ban status
fail2ban-client status sshd

# Status for the jail: sshd
#|- Filter
#|  |- Currently failed: 1
#|  |- Total failed:     6
#|  `- File list:        /var/log/auth.log
#`- Actions
#   |- Currently banned: 1
#   |- Total banned:     1
#   `- Banned IP list:   xxx.yyy.zzzz.hhh
