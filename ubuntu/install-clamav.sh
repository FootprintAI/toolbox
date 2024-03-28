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

# generate script for general running
cat <<EOF | tee /home/ubuntu/clamscan.sh
#!/usr/bin/env bash
echo "=======scanning \$(date '+%Y-%m-%d-%H:%M:%S')=========="
clamscan -ri --no-summary --exclude-dir="^/sys" /
echo "=======scanned \$(date '+%Y-%m-%d-%H:%M:%S')=========="
EOF

chmod +x /home/ubuntu/clamscan.sh
chown ubuntu:ubuntu /home/ubuntu/clamscan.sh

(crontab -u ubuntu -l 2>/dev/null; echo "03 3 * * *  /bin/bash /home/ubuntu/clamscan.sh 2>&1 >> clamav-scan.log") | crontab -u ubuntu -
