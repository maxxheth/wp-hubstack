#!/bin/bash

docker build --no-cache -t ghcr.io/ciwebgroup/advanced-wordpress:latest .
# docker build --no-cache --target production -t ghcr.io/ciwebgroup/advanced-wordpress:latest .