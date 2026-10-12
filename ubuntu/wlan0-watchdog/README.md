# wlan0-watchdog

Restarts a WiFi uplink (`wlan0`) when it loses connectivity. Meant for
hosts whose only network path is WiFi, where an unconditional periodic
restart would needlessly drop every connection.

## How it works

Every 5 minutes (cron) the script pings the default gateway, `1.1.1.1` and
`8.8.8.8` through `wlan0`. If any answers, it exits. (The gateway is not
trusted alone: some routers don't answer ICMP.) If none answer it runs:

    systemctl restart netplan-wpa-wlan0.service
    networkctl reconfigure wlan0

waits 20 seconds, re-checks, and logs `recovered` or `STILL DOWN` to
`/var/log/wlan0-watchdog.log`. A lock prevents overlapping runs.

## Assumptions

- Ubuntu with netplan (networkd renderer) and a `wifis:` entry for `wlan0`,
  which creates the `netplan-wpa-wlan0.service` unit. Adjust `IFACE` and the
  unit name for other setups.
- Run as root.

## Install

    sudo install -m 0755 wlan0-watchdog.sh /usr/local/sbin/wlan0-watchdog.sh
    sudo install -m 0644 wlan0-watchdog.cron /etc/cron.d/wlan0-watchdog

## Test without cutting your SSH session

Drop outgoing ICMP on the interface so the checks fail while TCP keeps
working, run the script detached, and remove the rule shortly after:

    R="-o wlan0 -p icmp --icmp-type echo-request -j DROP"
    sudo iptables -I OUTPUT $R
    sudo nohup bash -c "sleep 15; iptables -D OUTPUT $R" </dev/null >/dev/null 2>&1 &
    sudo nohup /usr/local/sbin/wlan0-watchdog.sh </dev/null >/dev/null 2>&1 &
    cat /var/log/wlan0-watchdog.log   # expect: restarting ... recovered
