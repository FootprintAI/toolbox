#!/usr/bin/env bash

ssh -i <private-key> rancher@<ip> "sudo tar czf - /oem" > oem-$date.tar.gz
