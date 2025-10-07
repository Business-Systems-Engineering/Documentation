# Stage 1: Builder (install deps, build MkDocs)
FROM python:3.12-slim AS builder

# Install build deps
RUN apt-get update && \
    apt-get install -y curl && \
    rm -rf /var/lib/apt/lists/*

# Create non-root user
RUN groupadd --gid 1000 worker && \
    adduser --uid 1000 --gid 1000 --disabled-password --gecos "" worker

WORKDIR /builder

ENV PATH="/home/worker/.local/bin:${PATH}"
ENV GIT_PYTHON_REFRESH=quiet

# Copy and install Python deps as worker
COPY --chown=worker:worker requirements.txt .

USER worker

RUN pip install --user --no-cache-dir --upgrade pip && \
    pip install --user --no-cache-dir -r requirements.txt

# Copy MkDocs project
COPY --chown=worker:worker mkdocs.yml ./
COPY --chown=worker:worker docs/ /builder/docs/
COPY --chown=worker:worker site/ /builder/site/

RUN ls -hal /builder

RUN mkdocs build --strict --site-dir site

# Stage 2: Runtime (Caddy serves the built site)
FROM debian:bookworm-slim AS runtime

# Install Caddy
RUN apt-get update && \
    apt-get install -y curl ca-certificates gnupg && \
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg && \
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | tee /etc/apt/sources.list.d/caddy-stable.list && \
    # sed -i 's/^deb/deb $$ signed-by=\/usr\/share\/keyrings\/caddy-stable-archive-keyring.gpg $$/g' /etc/apt/sources.list.d/caddy-stable.list && \
    apt-get update && \
    apt-get install -y caddy && \
    rm -rf /var/lib/apt/lists/*

# Create non-root user (reuse UID/GID for volume mounts)
RUN groupadd --gid 1000 worker && \
    adduser --uid 1000 --gid 1000 --disabled-password --gecos "" worker && \
    mkdir -p /mkdocs /var/log/caddy && \
    chown -R worker:worker /mkdocs /var/log/caddy

# Copy built site and configs
COPY --from=builder --chown=worker:worker /builder/site /mkdocs/site

COPY Caddyfile /etc/caddy/Caddyfile

COPY --chown=worker:worker entrypoint.sh /entrypoint.sh

RUN chmod +x /entrypoint.sh && chmod 644 /etc/caddy/Caddyfile

ENV MKDOCS_PORT=8080
ENV MKDOCS_DIR=/mkdocs/site

WORKDIR ${MKDOCS_DIR}

USER worker

EXPOSE ${MKDOCS_PORT}

HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 CMD curl -f http://localhost:${MKDOCS_PORT}/ || exit 2

ENTRYPOINT ["/entrypoint.sh"]
