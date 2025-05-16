#!/usr/bin/env bash

// tar all /var/log
tar xzvf var-log.tar.gz /var/log/

scp $remote-machine:/var/log/var-log.tar.gz ./
