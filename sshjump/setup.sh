#!/bin/bash
set -e

echo "Setting up SSH Jump Server environment..."

# Create directory structure
mkdir -p config/authorized_keys
mkdir -p config/allowed_cidrs
mkdir -p config/outbound_allowed
mkdir -p logs/clamav
mkdir -p logs/fail2ban
mkdir -p scripts

# Create the ClamAV installation script
cat > "scripts/install-clamav.sh" << 'EOF'
#!/bin/bash
set -e

# ClamAV installation and configuration script
echo "Installing ClamAV..."
apt-get update
apt-get install -y clamav clamav-daemon clamav-freshclam

# Stop services to configure
systemctl stop clamav-freshclam || true
systemctl stop clamav-daemon || true

# Configure ClamAV
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

# Create scan configuration
cat > /etc/clamav/scan.conf << 'EOFINNER'
# ClamAV scan configuration
LogFile /var/log/clamav/scan.log
LogTime yes
LogVerbose yes
LogSyslog yes
LogRotate yes

# Limit on file size to be scanned (100MB)
MaxFileSize 100M

# Limit on recursion level
MaxRecursion 10

# Don't scan files larger than this limit
MaxScanSize 100M
EOFINNER

# Create scan script
cat > /usr/local/bin/clamav-scan.sh << 'EOFINNER'
#!/bin/bash
set -e

# Define log file
LOG_FILE="/var/log/clamav/scan_$(date +\%Y\%m\%d_\%H\%M\%S).log"

echo "Starting ClamAV scan at $(date)" | tee -a "$LOG_FILE"

# Run clamscan
clamscan --infected --recursive=yes --log="$LOG_FILE" /home

# Check if any viruses were found
VIRUSES=$(grep -c "FOUND" "$LOG_FILE" || echo "0")

if [ "$VIRUSES" -gt 0 ]; then
    echo "ALERT: $VIRUSES viruses found during scan!" | tee -a "$LOG_FILE"
    # You can add notification commands here (e.g., email alerts)
else
    echo "No viruses found." | tee -a "$LOG_FILE"
fi

echo "ClamAV scan completed at $(date)" | tee -a "$LOG_FILE"

# Rotate logs if needed
find /var/log/clamav -name "scan_*.log" -type f -mtime +30 -delete
EOFINNER

chmod +x /usr/local/bin/clamav-scan.sh

# Create cron job for daily scans
cat > /etc/cron.d/clamav-cron << 'EOFINNER'
# Run ClamAV scan daily at 2 AM
0 2 * * * root /usr/local/bin/clamav-scan.sh >/dev/null 2>&1
EOFINNER

chmod 0644 /etc/cron.d/clamav-cron

# Update virus definitions
echo "Updating ClamAV virus definitions..."
freshclam || true

echo "ClamAV installation and configuration completed successfully."
EOF
chmod +x "scripts/install-clamav.sh"

# Create the Fail2ban installation script
cat > "scripts/install-fail2ban.sh" << 'EOF'
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
EOF
chmod +x "scripts/install-fail2ban.sh"

# Create the entrypoint script
cat > "scripts/entrypoint.sh" << 'EOF'
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

# Start rsyslog for logging
log "Starting rsyslog service..."
service rsyslog start || log "WARNING: Failed to start rsyslog"

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

# Configure fail2ban
log "Configuring fail2ban..."
if [ -f /etc/fail2ban/jail.local ]; then
    sed -i "s/bantime = .*/bantime = $F2B_BANTIME/" /etc/fail2ban/jail.local
    sed -i "s/maxretry = .*/maxretry = $F2B_MAXRETRY/" /etc/fail2ban/jail.local
    sed -i "s/findtime = .*/findtime = $F2B_FINDTIME/" /etc/fail2ban/jail.local
fi

# Start services
log "Starting services..."
service clamav-freshclam start || log "WARNING: clamav-freshclam service failed to start"
service clamav-daemon start || log "WARNING: clamav-daemon service failed to start"
service fail2ban start || log "WARNING: Failed to start fail2ban"
service cron start || log "WARNING: Failed to start cron service"

# Configure ClamAV scan schedule
log "Configuring ClamAV scan schedule..."
if [ -f /etc/cron.d/clamav-cron ]; then
    sed -i "s|0 2 \* \* \*|$CLAMAV_SCAN_SCHEDULE|" /etc/cron.d/clamav-cron
fi

# Configure inbound firewall restrictions (who can connect to the jump server)
log "Configuring inbound connection restrictions..."

# Create a new iptables chain for our inbound CIDR rules
iptables -F JUMP_CIDRS 2>/dev/null || iptables -N JUMP_CIDRS
iptables -F JUMP_CIDRS

# By default, drop all incoming connections to SSH
iptables -D INPUT -p tcp --dport 22 -j JUMP_CIDRS 2>/dev/null || true
iptables -A INPUT -p tcp --dport 22 -j JUMP_CIDRS

# Allow established connections
iptables -A JUMP_CIDRS -m state --state ESTABLISHED,RELATED -j ACCEPT

# Always allow localhost
iptables -A JUMP_CIDRS -s 127.0.0.1/32 -j ACCEPT

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

# Add final rule to log and drop all other inbound connections
iptables -A JUMP_CIDRS -j LOG --log-prefix "SSH JUMP INBOUND BLOCKED: " --log-level 4
iptables -A JUMP_CIDRS -j DROP

log "Added $cidr_count inbound CIDR whitelist entries"

# Show warning if no CIDRs were added
if [ "$cidr_count" -eq 0 ]; then
    log "WARNING: No inbound CIDR whitelist entries were found outside of localhost."
    log "Add CIDR ranges to files in the 'config/allowed_cidrs' directory and restart the container."
fi

# Configure outbound restrictions if enabled (where users can connect to)
if [ "$ENABLE_OUTBOUND_RESTRICTIONS" = "true" ]; then
    log "Setting up outbound connection restrictions..."
    
    # Create directory for outbound allowed destinations if it doesn't exist
    mkdir -p /etc/jump-server/outbound_allowed
    
    # Create a new iptables chain for our outbound rules
    iptables -F JUMP_OUTBOUND 2>/dev/null || iptables -N JUMP_OUTBOUND
    iptables -F JUMP_OUTBOUND
    
    # Remove any existing rules if present (for restarting)
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
    
    # Add final rule to log and drop all other outbound connections
    iptables -A JUMP_OUTBOUND -j LOG --log-prefix "SSH JUMP OUTBOUND BLOCKED: " --log-level 4
    iptables -A JUMP_OUTBOUND -j DROP
    
    log "Added $destination_count outbound destination restrictions"
    
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
    iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
fi

log "SSH jump server configuration completed successfully!"
log "Listening on port 22 (mapped to host port)"

# Start SSH daemon in foreground mode
exec /usr/sbin/sshd -D
EOF
chmod +x "scripts/entrypoint.sh"

# Create a default CIDR whitelist file if it doesn't exist
if [ ! -f "config/allowed_cidrs/default.cidr" ]; then
    echo "Creating default CIDR whitelist..."
    cat > "config/allowed_cidrs/default.cidr" << EOF
# Default allowed CIDRs for SSH Jump Server
# Add one CIDR per line
# Lines starting with # are comments

# Always allow localhost
127.0.0.1/32

# Example: Allow entire home/office network
# 192.168.1.0/24

# Example: Allow specific IP
# 203.0.113.42/32
EOF
    echo "Created default CIDR whitelist at config/allowed_cidrs/default.cidr"
fi

# Create a default outbound destinations file if it doesn't exist
if [ ! -f "config/outbound_allowed/default.list" ]; then
    echo "Creating default outbound destinations list..."
    cat > "config/outbound_allowed/default.list" << EOF
# Default allowed outbound SSH destinations
# Add one CIDR or IP per line
# Lines starting with # are comments

# Example: Allow connection to internal servers
# 10.0.0.0/8

# Example: Allow connection to specific server
# 203.0.113.42/32
EOF
    echo "Created default outbound destinations list at config/outbound_allowed/default.list"
fi

# Create Dockerfile if it doesn't exist
if [ ! -f "Dockerfile" ]; then
    echo "Creating Dockerfile..."
    cat > "Dockerfile" << EOF
FROM ubuntu:22.04

# Set noninteractive installation and environment variables
ENV DEBIAN_FRONTEND=noninteractive
ENV DEBUG=false
ENV TZ=UTC
ENV F2B_BANTIME=3600
ENV F2B_MAXRETRY=3
ENV F2B_FINDTIME=600
ENV CLAMAV_SCAN_SCHEDULE="0 2 * * *"
ENV ENABLE_OUTBOUND_RESTRICTIONS=false

# Install required packages
RUN apt-get update && apt-get install -y \\
    openssh-server \\
    fail2ban \\
    clamav \\
    clamav-daemon \\
    clamav-freshclam \\
    curl \\
    iptables \\
    iputils-ping \\
    logrotate \\
    git \\
    python3 \\
    python3-pip \\
    nano \\
    tzdata \\
    rsyslog \\
    && apt-get clean \\
    && rm -rf /var/lib/apt/lists/*

# Create necessary directories
RUN mkdir -p /var/run/sshd \\
    && mkdir -p /root/.ssh \\
    && mkdir -p /etc/jump-server/authorized_keys \\
    && mkdir -p /etc/jump-server/allowed_cidrs \\
    && mkdir -p /etc/jump-server/outbound_allowed \\
    && mkdir -p /var/log/clamav \\
    && mkdir -p /var/log/fail2ban

# Set proper permissions for ClamAV
RUN mkdir -p /var/log/clamav \\
    && touch /var/log/clamav/freshclam.log \\
    && touch /var/log/clamav/clamav.log \\
    && mkdir -p /var/lib/clamav \\
    && chown -R clamav:clamav /var/log/clamav /var/lib/clamav \\
    && chmod 755 /var/log/clamav /var/lib/clamav \\
    && chmod 644 /var/log/clamav/*.log

# Configure SSH
RUN sed -i 's/#PermitRootLogin prohibit-password/PermitRootLogin no/' /etc/ssh/sshd_config \\
    && sed -i 's/#PasswordAuthentication yes/PasswordAuthentication no/' /etc/ssh/sshd_config \\
    && sed -i 's/#LogLevel INFO/LogLevel VERBOSE/' /etc/ssh/sshd_config \\
    && echo "AllowUsers jump-user" >> /etc/ssh/sshd_config \\
    && echo "ClientAliveInterval 300" >> /etc/ssh/sshd_config \\
    && echo "ClientAliveCountMax 2" >> /etc/ssh/sshd_config

# Create jump user
RUN useradd -m -d /home/jump-user -s /bin/bash jump-user \\
    && mkdir -p /home/jump-user/.ssh \\
    && chmod 700 /home/jump-user/.ssh \\
    && chown jump-user:jump-user /home/jump-user/.ssh

# Copy installation scripts
COPY scripts/install-clamav.sh /tmp/install-clamav.sh
COPY scripts/install-fail2ban.sh /tmp/install-fail2ban.sh
RUN chmod +x /tmp/install-clamav.sh /tmp/install-fail2ban.sh

# Install and configure ClamAV and Fail2ban
RUN /tmp/install-clamav.sh
RUN /tmp/install-fail2ban.sh

# Copy entrypoint script
COPY scripts/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# Expose SSH port
EXPOSE 22

# Run entrypoint script
ENTRYPOINT ["/entrypoint.sh"]
CMD ["/usr/sbin/sshd", "-D"]
EOF
    echo "Created Dockerfile"
fi

# Create docker-compose.yml if it doesn't exist
if [ ! -f "docker-compose.yml" ]; then
    echo "Creating docker-compose.yml..."
    cat > "docker-compose.yml" << EOF
version: '3.8'

services:
  ssh-jump-server:
    build:
      context: .
      dockerfile: Dockerfile
    container_name: ssh-jump-server
    restart: always
    ports:
      - "2222:22"  # Map SSH port to 2222 on host
    volumes:
      # Mount authorized_keys directory for SSH public keys
      - ./config/authorized_keys:/etc/jump-server/authorized_keys
      # Mount allowed CIDRs directory for IP whitelisting (inbound)
      - ./config/allowed_cidrs:/etc/jump-server/allowed_cidrs
      # Mount allowed destinations for outbound connections
      - ./config/outbound_allowed:/etc/jump-server/outbound_allowed
      # Mount logs for persistence
      - ./logs/clamav:/var/log/clamav
      - ./logs/fail2ban:/var/log/fail2ban
      # Add a named volume for ClamAV database to prevent permission issues
      - clamav-db:/var/lib/clamav
    cap_add:
      - NET_ADMIN  # Required for iptables modifications
    environment:
      # Timezone setting (change as needed)
      - TZ=UTC
      
      # Debug mode (set to true for verbose logging)
      - DEBUG=false
      
      # fail2ban configuration
      - F2B_BANTIME=3600      # Ban time in seconds (1 hour)
      - F2B_MAXRETRY=3        # Max retry attempts before ban
      - F2B_FINDTIME=600      # Time window in seconds (10 minutes)
      
      # ClamAV configuration
      - CLAMAV_SCAN_SCHEDULE=0 2 * * *  # Daily at 2 AM
      
      # Enable/disable outbound restrictions
      - ENABLE_OUTBOUND_RESTRICTIONS=true
    
    # Configure health check
    healthcheck:
      test: ["CMD", "nc", "-z", "localhost", "22"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 20s

volumes:
  # Named volume for ClamAV database
  clamav-db:
EOF
    echo "Created docker-compose.yml"
fi

# Function to add a public key
add_public_key() {
    read -p "Enter the path to your SSH public key file (e.g., ~/.ssh/id_rsa.pub): " key_path
    
    if [ -f "$key_path" ]; then
        key_name=$(basename "$key_path")
        cp "$key_path" "config/authorized_keys/$key_name"
        echo "Added key: $key_name"
    else
        echo "Error: File not found at $key_path"
        return 1
    fi
}

# Function to add an inbound CIDR
add_inbound_cidr() {
    read -p "Enter CIDR notation to whitelist for inbound connections (e.g., 192.168.1.0/24): " cidr
    
    if [[ $cidr =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}(/[0-9]{1,2})?$ ]]; then
        echo "$cidr" >> "config/allowed_cidrs/default.cidr"
        echo "Added inbound CIDR: $cidr"
    else
        echo "Error: Invalid CIDR notation. Format should be like 192.168.1.0/24"
        return 1
    fi
}

# Function to add an outbound destination
add_outbound_destination() {
    read -p "Enter CIDR notation for allowed outbound connection (e.g., 10.0.0.0/8): " cidr
    
    if [[ $cidr =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}(/[0-9]{1,2})?$ ]]; then
        echo "$cidr" >> "config/outbound_allowed/default.list"
        echo "Added outbound destination: $cidr"
    else
        echo "Error: Invalid CIDR or IP notation. Format should be like 192.168.1.0/24 or 192.168.1.1"
        return 1
    fi
}

# Ask user about adding public keys
echo
echo "Do you want to add SSH public keys now? (y/n)"
read -r response
if [[ "$response" =~ ^([yY][eE][sS]|[yY])$ ]]; then
    while true; do
        add_public_key
        echo "Add another public key? (y/n)"
        read -r continue_response
        if [[ ! "$continue_response" =~ ^([yY][eE][sS]|[yY])$ ]]; then
            break
        fi
    done
fi

# Ask user about adding inbound CIDR ranges
echo
echo "Do you want to add inbound CIDR whitelist entries now? (y/n)"
read -r response
if [[ "$response" =~ ^([yY][eE][sS]|[yY])$ ]]; then
    while true; do
        add_inbound_cidr
        echo "Add another inbound CIDR? (y/n)"
        read -r continue_response
        if [[ ! "$continue_response" =~ ^([yY][eE][sS]|[yY])$ ]]; then
            break
        fi
    done
fi

# Ask user about adding outbound destinations
echo
echo "Do you want to add outbound SSH destinations now? (y/n)"
read -r response
if [[ "$response" =~ ^([yY][eE][sS]|[yY])$ ]]; then
    while true; do
        add_outbound_destination
        echo "Add another outbound destination? (y/n)"
        read -r continue_response
        if [[ ! "$continue_response" =~ ^([yY][eE][sS]|[yY])$ ]]; then
            break
        fi
    done
fi

echo
echo "Setup completed successfully!"
echo "You can now start the SSH Jump Server with:"
echo "  docker-compose up -d"
echo
echo "To manage your SSH Jump Server:"
echo "  - Add public keys to config/authorized_keys/"
echo "  - Add inbound CIDR whitelists to config/allowed_cidrs/"
echo "  - Add outbound allowed destinations to config/outbound_allowed/"
echo "  - View logs in the logs/ directory"
echo
echo "To connect to your jump server:"
echo "  ssh jump-user@your-server-ip -p 2222 -i /path/to/your/private_key"
