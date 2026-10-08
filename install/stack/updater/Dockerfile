FROM docker:28.5.1-cli AS docker
FROM ruby:4.0.7-slim

RUN apt-get update && apt-get install --no-install-recommends -y ca-certificates \
    && rm -rf /var/lib/apt/lists/*
COPY --from=docker /usr/local/bin/docker /usr/local/bin/docker
COPY --from=docker /usr/local/libexec/docker/cli-plugins /usr/local/libexec/docker/cli-plugins
WORKDIR /app
COPY updater.rb ./updater.rb
COPY lib ./lib
CMD ["ruby", "/app/updater.rb", "serve"]
