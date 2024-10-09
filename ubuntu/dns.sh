### this script helps you to setup dns server

cat dnsmasq.conf
```
# Listen on all network interfaces
listen-address=0.0.0.0
# Add domain records
address=/example.local/192.168.1.34

```

# disable port 53 as it is used in systemd

```
sudo systemctl disable systemd-resolved.service
sudo systemctl stop systemd-resolved
```

# to run docker compose
```
wget https://raw.githubusercontent.com/TechnitiumSoftware/DnsServer/refs/heads/master/docker-compose.yml
```

```
docker compose up -d
```

# connect with port 5380. http://localhost:5380
