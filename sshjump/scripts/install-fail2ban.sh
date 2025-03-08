#!/bin/bash
set -e

# Fail2ban installation and configuration script
echo "Installing Fail2ban..."
apt-get update
apt-get install -y fail2ban iptables

# Create custom jail configuration
cat > /etc/fail2ban/jail.local << 'EOFINNER'
[DEFAULT]
# Ban hosts for one hour (3600 seconds):
bantime = 3600

# Find attempts in the last 10 minutes (600 seconds):
findtime = 600

# Ban after 5 attempts:
maxretry = 5

# Use iptables for banning
banaction = iptables-multiport

# JAILS
[sshd]
enabled = true
port = ssh
filter = sshd
logpath = /var/log/auth.log
maxretry = 3
bantime = 3600

[sshd-ddos]
enabled = true
port = ssh
filter = sshd-ddos
logpath = /var/log/auth.log
maxretry = 5
bantime = 7200

[recidive]
enabled = true
filter = recidive
logpath = /var/log/fail2ban.log
action = iptables-allports[name=recidive]
bantime = 604800  ; 1 week
findtime = 86400   ; 1 day
maxretry = 5
EOFINNER

# Create custom filter for SSH DDoS protection
cat > /etc/fail2ban/filter.d/sshd-ddos.conf << 'EOFINNER'
[Definition]
failregex = ^.*sshd\[\d+\]: Connection from <HOST> port \d+ on \S+ port \d+$
            ^.*sshd\[\d+\]: error: maximum authentication attempts exceeded for .* from <HOST> port \d+ ssh2$
            ^.*sshd\[\d+\]: message repeated \d+ times: \[ Failed password for .* from <HOST> port \d+ ssh2\]$
ignoreregex =
EOFINNER

# Create fail2ban status check script
cat > /usr/local/bin/fail2ban-status.sh << 'EOFINNER'
#!/bin/bash

# Get status of all jails
echo "=== Fail2Ban Status ==="
fail2ban-client status

# Get detailed status of SSH jail
echo -e "\n=== SSH Jail Details ==="
fail2ban-client status sshd

# List currently banned IPs
echo -e "\n=== Currently Banned IPs ==="
iptables -L -n | grep 'f2b\|Chain INPUT' | grep -v 'Chain'
EOFINNER

chmod +x /usr/local/bin/fail2ban-status.sh

echo "Fail2ban installation and configuration completed successfully."
