# syntax=docker/dockerfile:1
# check=error=true

# This Dockerfile is designed for production, not development. Use with Kamal or build'n'run by hand:
# docker build -t nexus .
# docker run -d -p 80:80 -e SECRET_KEY_BASE=<bin/rails secret> -e SOLID_QUEUE_IN_PUMA=true --name nexus nexus
# (SOLID_QUEUE_IN_PUMA runs the job supervisor in-process; without it — as in
# compose.yaml, which runs bin/jobs as its own service — no jobs execute.)

# For a containerized dev environment, see Dev Containers: https://guides.rubyonrails.org/getting_started_with_devcontainer.html

# Make sure RUBY_VERSION matches the Ruby version in .ruby-version
ARG RUBY_VERSION=4.0.7

# JavaScript and CSS are architecture-independent output. Build them natively:
# Bun's JavaScriptCore allocator cannot reliably run through QEMU during cross-builds.
FROM --platform=$BUILDPLATFORM docker.io/library/ruby:$RUBY_VERSION-slim AS assets
WORKDIR /rails
RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y curl unzip && \
    rm -rf /var/lib/apt/lists /var/cache/apt/archives
ENV BUN_INSTALL=/usr/local/bun
ENV PATH=/usr/local/bun/bin:$PATH
ARG BUN_VERSION=1.4.2
RUN curl -fsSL https://bun.sh/install | bash -s -- "bun-v${BUN_VERSION}"
COPY package.json bun.lock* ./
RUN bun install --frozen-lockfile
COPY . .
RUN bun run --bun build && bun run --bun build:css

FROM docker.io/library/ruby:$RUBY_VERSION-slim AS base

# Rails app lives here
WORKDIR /rails

# Install base packages
RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y curl libjemalloc2 libvips postgresql-client && \
    ln -s /usr/lib/$(uname -m)-linux-gnu/libjemalloc.so.2 /usr/local/lib/libjemalloc.so && \
    rm -rf /var/lib/apt/lists /var/cache/apt/archives

# Set production environment variables and enable jemalloc for reduced memory usage and latency.
# Thruster logs raw query strings, so Rails owns the filtered request log instead. Its request cap
# rejects an oversized multipart envelope before Rack spools it; the application still owns the
# exact 100 MiB uploaded-file bound.
ENV RAILS_ENV="production" \
    THRUSTER_LOG_REQUESTS="false" \
    MAX_REQUEST_BODY="115343360" \
    BUNDLE_DEPLOYMENT="1" \
    BUNDLE_PATH="/usr/local/bundle" \
    BUNDLE_WITHOUT="development:test" \
    LD_PRELOAD="/usr/local/lib/libjemalloc.so"

# Throw-away build stage to reduce size of final image
FROM base AS build

# Install packages needed to build gems
RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y build-essential git libpq-dev libyaml-dev pkg-config unzip && \
    rm -rf /var/lib/apt/lists /var/cache/apt/archives

# Install application gems
COPY vendor/simple_inference ./vendor/simple_inference
COPY Gemfile Gemfile.lock ./

RUN bundle install && \
    rm -rf ~/.bundle/ "${BUNDLE_PATH}"/ruby/*/cache "${BUNDLE_PATH}"/ruby/*/bundler/gems/*/.git && \
    # -j 1 disable parallel compilation to avoid a QEMU bug: https://github.com/rails/bootsnap/issues/495
    bundle exec bootsnap precompile -j 1 --gemfile

# Copy application code
COPY . .
COPY --from=assets /rails/app/assets/builds ./app/assets/builds

# Precompile bootsnap code for faster boot times.
# -j 1 disable parallel compilation to avoid a QEMU bug: https://github.com/rails/bootsnap/issues/495
RUN bundle exec bootsnap precompile -j 1 app/ lib/

# The bundling gems' skip flags leave Propshaft to digest the native-built assets.
RUN SECRET_KEY_BASE_DUMMY=1 SKIP_JS_BUILD=1 SKIP_CSS_BUILD=1 ./bin/rails assets:precompile


# Final stage for app image
FROM base

# Run and own only the runtime files as a non-root user for security
RUN groupadd --system --gid 1000 rails && \
    useradd rails --uid 1000 --gid 1000 --create-home --shell /bin/bash
USER 1000:1000

# Copy built artifacts: gems, application
COPY --chown=rails:rails --from=build "${BUNDLE_PATH}" "${BUNDLE_PATH}"
COPY --chown=rails:rails --from=build /rails /rails

# Entrypoint prepares the database.
ENTRYPOINT ["/rails/bin/docker-entrypoint"]

# Start server via Thruster by default, this can be overwritten at runtime
EXPOSE 80
CMD ["./bin/thrust", "./bin/rails", "server"]
