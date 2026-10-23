FROM docker:29.9.2-cli AS docker
# Docker's latest published Ruby image as of 2026-10-24.
FROM ruby:4.0.8-slim

RUN apt-get update && apt-get install --no-install-recommends -y ca-certificates \
    && rm -rf /var/lib/apt/lists/*
COPY --from=docker /usr/local/bin/docker /usr/local/bin/docker
COPY --from=docker /usr/local/libexec/docker/cli-plugins /usr/local/libexec/docker/cli-plugins
WORKDIR /app
COPY updater/updater.rb ./updater.rb
COPY updater/lib ./lib
COPY --chmod=755 install.sh /usr/local/share/cybros/install.sh
CMD ["ruby", "/app/updater.rb", "serve"]
