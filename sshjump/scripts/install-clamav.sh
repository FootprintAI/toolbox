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
chown clamav:clamav /var/log/clamav

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
