#!/bin/bash

set -e

cd ${MKDOCS_DIR}

# mkdocs build --strict

caddy run --config /etc/caddy/Caddyfile --adapter caddyfile
