# Set up Nexus development on macOS

Use this guide to run Nexus from source and work on its Rails application. It
covers local dependencies, secrets, databases and tests. To run Nexus and rho
together without a development checkout, [install the stack](install.md).

## Install the tools

Install Apple's command-line tools with `xcode-select --install` if needed, then
install [Homebrew](https://brew.sh/). In a new terminal:

```sh
brew install git rbenv ruby-build postgresql@18 vips pkgconf
```

Install [Bun](https://bun.sh/docs/installation) for asset builds. Node.js is not
required for Nexus's JavaScript and CSS builds.

These examples use macOS's default zsh. Add the following to `~/.zshrc`, then
open a new terminal:

```sh
export PATH="$(brew --prefix postgresql@18)/bin:$PATH"
eval "$(rbenv init - zsh)"
```

[rbenv](https://github.com/rbenv/rbenv) selects Ruby from the checkout's
`.ruby-version`. Avoid macOS's system Ruby.

## Check out the repository

```sh
git clone https://github.com/jasl/cybros.ai.git
cd cybros.ai/nexus
rbenv install -s "$(cat .ruby-version)"
gem install bundler
ruby --version
bun --version
git --version
```

Run the remaining Nexus commands from this `nexus` directory. Keep the locked
gem versions when installing dependencies; `bundle update` is not a setup step.

## Start PostgreSQL

For a new local database cluster:

```sh
brew services start postgresql@18
pg_isready
psql -d postgres -c 'SHOW server_version;'
```

[Homebrew PostgreSQL 18](https://formulae.brew.sh/formula/postgresql@18) creates
a local cluster during installation. The default connection uses your macOS
username over a Unix socket. Use a role that can create databases, including the
additional databases created by parallel tests.

If another PostgreSQL service already uses port 5432, select the intended
service before proceeding. Check the server version through `psql`; the client
version alone does not identify the running server.

Nexus also supports PostgreSQL 17 with `pg_uuidv7`. Install that extension against
the server's own `pg_config`; migrations and schema loading enable it in primary
databases. PostgreSQL 18 has native UUIDv7 support and needs no extension.

## Configure local secrets

Rails can use encrypted credentials. This procedure instead uses a private
`nexus/.env`, loaded automatically by dotenv in development and tests:

```sh
test -e .env || install -m 600 env.sample .env
```

For a fresh template, run this once to fill its four commented secret fields.
Existing active values are preserved, so rerunning it does not rotate them:

```sh
ruby -rsecurerandom <<'RUBY'
path = ".env"
text = File.read(path)
keys = %w[SECRET_KEY_BASE ACTIVE_RECORD_ENCRYPTION__PRIMARY_KEY
  ACTIVE_RECORD_ENCRYPTION__DETERMINISTIC_KEY
  ACTIVE_RECORD_ENCRYPTION__KEY_DERIVATION_SALT]
keys.each do |key|
  next if text.match?(/^#{key}=.+$/)
  pattern = /^# ?#{key}=[ \t]*$/
  abort "Expected a blank template field for #{key}" unless text.match?(pattern)
  text.sub!(pattern, "#{key}=#{SecureRandom.hex(key == 'SECRET_KEY_BASE' ? 64 : 32)}")
end
File.write(path, text)
File.chmod(0600, path)
RUBY
```

Keep `.env` untracked and retain these values across restarts. Changing encryption
keys makes previously encrypted provider credentials unreadable. Real provider
API keys are unnecessary for the default test suite, which uses fake transports.

For Homebrew's default local connection, leave the database fields commented.
For a different local server, set `PGHOST`, `PGPORT`, `PGUSER` and `PGPASSWORD`
as needed. `POSTGRES_PASSWORD` in the template configures Docker Compose's bundled
database; it does not configure the local Rails connection.

Test database overrides are `RAILS_TEST_APP_DB_NAME` and
`RAILS_TEST_CABLE_DB_NAME`. Keep them separate from development and production:
test preparation replaces their contents. Leave production origin and SSL
settings commented for ordinary localhost development.

## Prepare and test Nexus

```sh
bin/setup
bin/download-tokenizers --check
bin/rails test
```

`bin/setup` installs gems and Bun packages, downloads the pinned tokenizer assets,
creates Rails credentials if absent, and prepares databases. It never creates
`.env`. Tokenizer downloads need network access during setup; runtime token
counting only reads the installed files. No model weights are downloaded.

Run Rails suites sequentially. Parallel test workers are managed by Rails; do
not start a second test or database preparation command against the same test
databases. For a cleanup-related deadlock, rerun the affected test with
`PARALLEL_WORKERS=1`. Use `bin/ci` for the full local pipeline, including system
tests; it has additional requirements such as a browser.

## Start development

```sh
bin/dev
```

Open `http://localhost:3000/setup` to create the first Human owner. The development
processes include Rails, jobs, the model runner, and asset watchers. Configure
model access through [Models and providers](../operate/models-and-providers.md)
when you want to make real model requests.

## Troubleshoot setup

- **Missing Active Record encryption credential:** check that all three
  `ACTIVE_RECORD_ENCRYPTION__...` fields are active and nonempty in `nexus/.env`.
  A `SECRET_KEY_BASE` alone does not configure attribute encryption.
- **`token_counter_unavailable`:** run `bin/download-tokenizers`, then
  `bin/download-tokenizers --check`. Restart processes after replacing assets;
  loaded tokenizers are cached in memory.
- **Database connection refused or role missing:** check `pg_isready`, the
  selected service, and your `PG*` variables. Create or select a database role
  with database-creation permission.

## Next

- [Build your own agent](build-an-agent.md) to develop another Nexus client.
- [Agent API quickstart](../build/quickstart.md) to connect an agent and send its first request.
- [Runner quickstart](../runners/quickstart.md) to serve tools from your machine.
