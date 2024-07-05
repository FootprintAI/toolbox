#!/usr/bin/env bash

# install docker and docker compose
see ref: https://github.com/FootprintAI/multikf/tree/main/hack/docker-install

# get docker-compose yaml
# ref: https://greenbone.github.io/docs/latest/22.4/container/
curl -f -L https://greenbone.github.io/docs/latest/_static/docker-compose-22.4.yml -o docker-compose.yml

# run
docker compose -f docker-compose.yml up -d

# wait a while for data sync and open browser
# http://localhost:9392
