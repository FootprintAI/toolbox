#!/bin/bash
set -e

# Function for logging
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

log "Starting SSH Jump Server initialization..."

# Enable debug mode if requested
if [ "$DEBUG" = "true" ]; then
    set -x
    log "Debug mode enabled"
fi

# Configure timezone
if [ ! -z "$TZ" ]; then
    log "Setting timezone to $TZ"
    ln -snf /usr/share/zoneinfo/$TZ /etc/localtime
    echo $TZ > /etc/timezone
fi

# Ensure proper permissions for SSH directory
log "Setting up SSH directory permissions"
chmod 700 /home/jump-user/.ssh
chown jump-user:jump-user /home/jump-user/.ssh

# Make sure auth.log exists for fail2ban
touch /var/log/auth.log

# Start rsyslog for logging
log "Starting rsyslog service..."
if command -v rsyslogd &> /dev/null; then
    service rsyslog start || rsyslogd || log "WARNING: Failed to start rsyslog"
else
    log "WARNING: rsyslog not installed"
fi

# Setup authorized keys
log "Setting up authorized SSH keys..."
> /home/jump-user/.ssh/authorized_keys
key_count=0

for key_file in /etc/jump-server/authorized_keys/*.pub; do
    if [ -f "$key_file" ]; then
        log "Adding authorized key: $(basename "$key_file")"
        cat "$key_file" >> /home/jump-user/.ssh/authorized_keys
        key_count=$((key_count+1))
    fi
done

chmod 600 /home/jump-user/.ssh/authorized_keys
chown jump-user:jump-user /home/jump-user/.ssh/authorized_keys

log "Added $key_count SSH public key(s)"

# Show warning if no keys were added
if [ "$key_count" -eq 0 ]; then
    log "WARNING: No SSH public keys were found. You won't be able to login!"
    log "Add .pub files to the 'config/authorized_keys' directory and restart the container."
fi

# Fix ClamAV permissions
log "Setting up ClamAV permissions..."
mkdir -p /var/log/clamav
touch /var/log/clamav/freshclam.log
touch /var/log/clamav/clamav.log
chown -R clamav:clamav /var/log/clamav
chmod 755 /var/log/clamav
chmod 644 /var/log/clamav/*.log

# Make sure the database directory exists with correct permissions
mkdir -p /var/lib/clamav
chown -R clamav:clamav /var/lib/clamav
chmod 755 /var/lib/clamav

# Stop any running ClamAV services before starting
log "Stopping any running ClamAV services..."
pkill clamd 2>/dev/null || true
pkill freshclam 2>/dev/null || true
rm -f /var/run/clamav/clamd.ctl 2>/dev/null || true

# Configure ClamAV scan schedule
log "Configuring ClamAV scan schedule..."
if [ -f /etc/cron.d/clamav-cron ]; then
    sed -i "s|0 2 \* \* \*|$CLAMAV_SCAN_SCHEDULE|" /etc/cron.d/clamav-cron
fi

# Start services
log "Starting services..."
service clamav-freshclam start || log "WARNING: clamav-freshclam service failed to start"
sleep 3  # Give freshclam time to initialize
service clamav-daemon start || log "WARNING: clamav-daemon service failed to start"
service cron start || log "WARNING: Failed to start cron service"

# Configure fail2ban
log "Configuring fail2ban..."
if [ -f /etc/fail2ban/jail.local ]; then
    sed -i "s/bantime = .*/bantime = $F2B_BANTIME/" /etc/fail2ban/jail.local
    sed -i "s/maxretry = .*/maxretry = $F2B_MAXRETRY/" /etc/fail2ban/jail.local
    sed -i "s/findtime = .*/findtime = $F2B_FINDTIME/" /etc/fail2ban/jail.local
    service fail2ban start || log "WARNING: Failed to start fail2ban"
else
    log "WARNING: fail2ban configuration file not found"
fi

# Configure inbound firewall restrictions (who can connect to the jump server)
log "Configuring inbound connection restrictions..."

# Clear any existing rules and set default policies
iptables -F
iptables -X JUMP_CIDRS 2>/dev/null || true
iptables -X JUMP_OUTBOUND 2>/dev/null || true

# Create a new iptables chain for our inbound CIDR rules
iptables -N JUMP_CIDRS

# By default, drop all incoming connections to SSH
iptables -A INPUT -p tcp --dport 22 -j JUMP_CIDRS

# Allow established connections
iptables -A JUMP_CIDRS -m state --state ESTABLISHED,RELATED -j ACCEPT

# Always allow connections from Docker host networks
iptables -A JUMP_CIDRS -s 172.16.0.0/12 -j ACCEPT
iptables -A JUMP_CIDRS -s 192.168.0.0/16 -j ACCEPT
iptables -A JUMP_CIDRS -s 10.0.0.0/8 -j ACCEPT
iptables -A JUMP_CIDRS -s 127.0.0.1/8 -j ACCEPT

# Process each CIDR in the allowed_cidrs directory (inbound)
cidr_count=0
for cidr_file in /etc/jump-server/allowed_cidrs/*.cidr; do
    if [ -f "$cidr_file" ]; then
        log "Processing inbound CIDR file: $(basename "$cidr_file")"
        while IFS= read -r line; do
            # Skip empty lines and comments
            if [[ -n "$line" && ! "$line" =~ ^[[:space:]]*# ]]; then
                log "Adding allowed inbound CIDR: $line"
                iptables -A JUMP_CIDRS -s "$line" -j ACCEPT
                cidr_count=$((cidr_count+1))
            fi
        done < "$cidr_file"
    fi
done

# Log blocked connections
iptables -A JUMP_CIDRS -j LOG --log-prefix "SSH JUMP INBOUND BLOCKED: " --log-level 4

# Default action (set to ACCEPT by default, change to DROP for production use)
if [ "$STRICT_FIREWALL" = "true" ]; then
    log "STRICT_FIREWALL enabled - blocking non-whitelisted IPs"
    iptables -A JUMP_CIDRS -j DROP
else
    log "STRICT_FIREWALL disabled - allowing all IPs (for debugging)"
    iptables -A JUMP_CIDRS -j ACCEPT
fi

log "Added $cidr_count custom inbound CIDR whitelist entries"

# Configure outbound restrictions if enabled (where users can connect to)
if [ "$ENABLE_OUTBOUND_RESTRICTIONS" = "true" ]; then
    log "Setting up outbound connection restrictions..."
    
    # Create directory for outbound allowed destinations if it doesn't exist
    mkdir -p /etc/jump-server/outbound_allowed
    
    # Reset the outbound chain if it exists
    iptables -F JUMP_OUTBOUND 2>/dev/null || iptables -N JUMP_OUTBOUND
    iptables -F JUMP_OUTBOUND
    
    # Remove any existing rules that use this chain
    iptables -D OUTPUT -p tcp --dport 22 -m owner --uid-owner jump-user -j JUMP_OUTBOUND 2>/dev/null || true
    
    # Apply the chain to all outbound SSH traffic from jump-user
    iptables -A OUTPUT -p tcp --dport 22 -m owner --uid-owner jump-user -j JUMP_OUTBOUND
    
    # Allow established connections
    iptables -A JUMP_OUTBOUND -m state --state ESTABLISHED,RELATED -j ACCEPT
    
    # Count outbound allowed destinations
    destination_count=0
    
    # Process each destination list file
    for dest_file in /etc/jump-server/outbound_allowed/*.list; do
        if [ -f "$dest_file" ]; then
            log "Processing outbound destination file: $(basename "$dest_file")"
            while IFS= read -r line; do
                # Skip empty lines and comments
                if [[ -n "$line" && ! "$line" =~ ^[[:space:]]*# ]]; then
                    log "Adding allowed outbound destination: $line"
                    iptables -A JUMP_OUTBOUND -d "$line" -j ACCEPT
                    destination_count=$((destination_count+1))
                fi
            done < "$dest_file"
        fi
    done
    
    # Log and drop non-whitelisted destinations
    iptables -A JUMP_OUTBOUND -j LOG --log-prefix "SSH JUMP OUTBOUND BLOCKED: " --log-level 4
    iptables -A JUMP_OUTBOUND -j DROP
    
    log "Added $destination_count outbound destination restrictions"
    log "Outbound connections will be restricted to only whitelisted destinations"
    
    # Show warning if no destinations were added
    if [ "$destination_count" -eq 0 ]; then
        log "WARNING: No outbound destinations were allowed. Users won't be able to SSH anywhere!"
        log "Add destination CIDRs to files in the 'config/outbound_allowed' directory and restart the container."
    fi
else
    log "Outbound connection restrictions are disabled"
fi

# Save iptables rules (if iptables-persistent is installed)
if command -v iptables-save > /dev/null; then
    log "Saving iptables rules..."
    mkdir -p /etc/iptables
    iptables-save > /etc/iptables/rules.v4 2>/dev/null || log "WARNING: Failed to save iptables rules"
fi

log "SSH jump server configuration completed successfully!"
log "Listening on port 22 (mapped to host port)"

# Start SSH daemon in foreground mode
exec /usr/sbin/sshd -D
