# The search engine behind the chat's "Search" button (backend/apps/chat/websearch.py).
#
# SearXNG (https://docs.searxng.org) is an open-source metasearch engine: it
# asks Google, Bing, DuckDuckGo, Wikipedia... and merges the results. It needs
# no API key and keeps no logs. This image is SearXNG plus our settings.yml, so
# the same image runs locally (docker-compose.yml builds it) and on Google Cloud
# (Cloud Build builds it and pushes it to Artifact Registry; it runs on Cloud Run
# as a sidecar container next to the api, in the same instance).
#
# It listens on port 8080. Required at runtime: SEARXNG_SECRET (any long
# random string; SearXNG refuses to start with the default one).

# A dated release, so local and Google Cloud run the same version. Newer ones:
# https://hub.docker.com/r/searxng/searxng/tags
ARG SEARXNG_VERSION=2026.10.4-d48c4b555
FROM searxng/searxng:${SEARXNG_VERSION}

COPY settings.yml /etc/searxng/settings.yml

HEALTHCHECK --interval=10s --timeout=3s --start-period=10s --retries=5 \
  CMD wget -q -O /dev/null http://127.0.0.1:8080/healthz || exit 1
