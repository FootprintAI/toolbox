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
RUN apt-get update && apt-get install -y \
    openssh-server \
    fail2ban \
    clamav \
    clamav-daemon \
    clamav-freshclam \
    curl \
    iptables \
    iptables-persistent \
    iputils-ping \
    logrotate \
    git \
    python3 \
    python3-pip \
    nano \
    tzdata \
    rsyslog \
    netcat \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# Create necessary directories
RUN mkdir -p /var/run/sshd \
    && mkdir -p /root/.ssh \
    && mkdir -p /etc/jump-server/authorized_keys \
    && mkdir -p /etc/jump-server/allowed_cidrs \
    && mkdir -p /etc/jump-server/outbound_allowed \
    && mkdir -p /var/log/clamav \
    && mkdir -p /var/log/fail2ban \
    && mkdir -p /var/log/auth \
    && touch /var/log/auth.log

# Set proper permissions for ClamAV
RUN mkdir -p /var/log/clamav \
    && touch /var/log/clamav/freshclam.log \
    && touch /var/log/clamav/clamav.log \
    && mkdir -p /var/lib/clamav \
    && chown -R clamav:clamav /var/log/clamav /var/lib/clamav \
    && chmod 755 /var/log/clamav /var/lib/clamav \
    && chmod 644 /var/log/clamav/*.log

# Configure SSH
RUN sed -i 's/#PermitRootLogin prohibit-password/PermitRootLogin no/' /etc/ssh/sshd_config \
    && sed -i 's/#PasswordAuthentication yes/PasswordAuthentication no/' /etc/ssh/sshd_config \
    && sed -i 's/#LogLevel INFO/LogLevel VERBOSE/' /etc/ssh/sshd_config \
    && echo "AllowUsers jump-user" >> /etc/ssh/sshd_config \
    && echo "ClientAliveInterval 300" >> /etc/ssh/sshd_config \
    && echo "ClientAliveCountMax 2" >> /etc/ssh/sshd_config

# Create jump user
RUN useradd -m -d /home/jump-user -s /bin/bash jump-user \
    && mkdir -p /home/jump-user/.ssh \
    && chmod 700 /home/jump-user/.ssh \
    && chown jump-user:jump-user /home/jump-user/.ssh

# Fix fail2ban configuration
RUN mkdir -p /etc/fail2ban \
    && echo '[DEFAULT]\nbantime = 3600\nfindtime = 600\nmaxretry = 5\n\n[sshd]\nenabled = true\nport = ssh\nfilter = sshd\nlogpath = /var/log/auth.log\nmaxretry = 3\nbantime = 3600' > /etc/fail2ban/jail.local

# Copy entrypoint script
COPY scripts/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# Create directory for iptables rules
RUN mkdir -p /etc/iptables

# Expose SSH port
EXPOSE 22

# Run entrypoint script
ENTRYPOINT ["/entrypoint.sh"]
CMD ["/usr/sbin/sshd", "-D"]
