#!/bin/bash
# Restart wlan0 if the default gateway is unreachable. Run from cron as root.
IFACE=wlan0
LOG=/var/log/wlan0-watchdog.log
exec 9>/run/wlan0-watchdog.lock; flock -n 9 || exit 0
log() { echo "$(date -Is) $*" >> "$LOG"; }

# Healthy if any target answers via wlan0 (the gateway may not answer ICMP).
healthy() {
  local gw
  gw=$(ip -4 route show default dev "$IFACE" | awk '{print $3; exit}')
  for t in $gw 1.1.1.1 8.8.8.8; do
    ping -c2 -W2 -I "$IFACE" "$t" >/dev/null 2>&1 && return 0
  done
  return 1
}

healthy && exit 0

log "no connectivity via $IFACE; restarting"
systemctl restart netplan-wpa-wlan0.service
networkctl reconfigure "$IFACE"
sleep 20
if healthy; then
  log "recovered"
else
  log "STILL DOWN after restart"
fi
