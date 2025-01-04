#!/usr/bin/env bash

docker run -itd --restart=always --cap-add=NET_ADMIN \
	--device /dev/net/tun:/dev/net/tun \
	-p 1194:1194/udp -p 80:8080/tcp \
	-v openvpn_conf:/opt/Dockovpn_data \
	-v /var/log:/var/log \
	-v /home/ubuntu/config/server.conf:/etc/openvpn/server.conf \
	--name dockovpn alekslitvinenk/openvpn
