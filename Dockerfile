FROM python:3.12-slim AS base

RUN apt-get update && \
    apt-get install -y curl && \
    rm -rf /var/lib/apt/lists/*

RUN groupadd --gid 1000 worker && adduser --uid 1000 --gid 1000 --disabled-password --gecos "" worker

WORKDIR /docs

ENV PATH="/home/worker/.local/bin:${PATH}"
ENV GIT_PYTHON_REFRESH=quiet

COPY --chown=worker:worker requirements.txt .

USER worker

RUN pip install --user --no-cache-dir --upgrade pip && \
    pip install --user --no-cache-dir -r requirements.txt

# Development — live-reload server for authors.
#
# Intended to be used with a bind-mount of the repo at /docs (see
# docker-compose.yml). We still COPY the source in so the image is
# usable standalone, but the mount wins at runtime.
FROM base AS development

USER worker

WORKDIR /docs

COPY --chown=worker:worker mkdocs.yml .
COPY --chown=worker:worker docs/ ./docs/

EXPOSE 8000

# --dirty   : only rebuild files that changed (much faster on large repos)
# --watch-theme : reload when the Material theme or extra_css changes
# FORCE_COLOR : nicer log output in the terminal
ENV FORCE_COLOR=1
CMD ["mkdocs", "serve", \
     "--dev-addr=0.0.0.0:8000", \
     "--dirty", \
     "--watch-theme"]

# Builder — produces the static site inside /docs/site
FROM base AS gh-pages-builder

USER worker

WORKDIR /docs

COPY --chown=worker:worker mkdocs.yml .
COPY --chown=worker:worker docs/ ./docs/

RUN mkdocs build --strict --site-dir /home/worker/site

# Export stage — a scratch image containing ONLY the built site at the
# filesystem root. Used by CI with `docker buildx build --output type=local`
# so the exported tree is exactly the site contents, not the whole builder fs.
FROM scratch AS gh-pages-export
COPY --from=gh-pages-builder /home/worker/site/ /

# Runtime
FROM debian:bookworm-slim AS runtime

RUN apt-get update && \
    apt-get install -y curl ca-certificates gnupg && \
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg && \
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | tee /etc/apt/sources.list.d/caddy-stable.list && \
    apt-get update && \
    apt-get install -y caddy && \
    rm -rf /var/lib/apt/lists/*

RUN groupadd --gid 1000 worker && \
    adduser --uid 1000 --gid 1000 --disabled-password --gecos "" worker && \
    mkdir -p /docs/site /var/log/caddy && \
    chown -R worker:worker /docs /var/log/caddy

COPY --from=gh-pages-builder --chown=worker:worker /home/worker/site /docs/site

COPY Caddyfile /etc/caddy/Caddyfile

COPY --chown=worker:worker entrypoint.sh /entrypoint.sh

RUN chmod +x /entrypoint.sh && chmod 644 /etc/caddy/Caddyfile

ENV MKDOCS_PORT=8080
ENV MKDOCS_DIR=/docs/site

WORKDIR ${MKDOCS_DIR}

USER worker

EXPOSE ${MKDOCS_PORT}

HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 CMD curl -f http://localhost:${MKDOCS_PORT}/ || exit 2

ENTRYPOINT ["/entrypoint.sh"]
