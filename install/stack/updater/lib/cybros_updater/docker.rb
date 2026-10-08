module CybrosUpdater
  class Docker
    SERVICES = %w[rho jobs model_runner nexus].freeze
    PRODUCTS = %w[nexus rho].freeze

    def self.products(scope)
      case scope
      when "installation"
        PRODUCTS
      when "nexus"
        %w[nexus]
      else
        raise ArgumentError, "Unknown deployment scope."
      end
    end

    def initialize(directory:, repositories:, command: Command.new(directory), wait_timeout: 240, worker_observation: 5)
      @directory = directory
      @repositories = repositories
      @command = command
      @wait_timeout = wait_timeout
      @worker_observation = worker_observation
    end

    def installed(scope: "installation")
      products = self.class.products(scope)
      containers = service_containers(products)
      images = containers.map do |container|
        labels = container.fetch("Config").fetch("Labels")
        Image.new(name: labels.fetch("com.docker.compose.service"), reference: immutable_reference(container), version: labels["org.opencontainers.image.version"])
      end
      releases = images.map(&:version).uniq
      release = images.size == products.size && releases.size == 1 ? releases.first : nil
      Release.new(release: release, images: images.sort_by(&:name), checked_at: nil, source_revision: nil, source_url: nil)
    end

    def sources(scope: "installation")
      self.class.products(scope).map { |name| Image.new(name: name, reference: @repositories.fetch(name), version: nil) }
    end

    def check(tag, scope: "installation")
      deadline = monotonic + 60
      platform = run(["version", "--format", "{{.Server.Os}}/{{.Server.Arch}}"], timeout: 5).output.strip
      os, architecture = platform.split("/", 2)
      images = []
      labels = []
      self.class.products(scope).each do |product|
        repository = @repositories.fetch(product)
        manifest = registry_json("#{repository}:#{tag}", "{{json .Manifest}}", deadline)
        if manifest["manifests"]
          manifest = manifest.fetch("manifests").find do |entry|
            entry.fetch("platform", {})["os"] == os && entry.fetch("platform", {})["architecture"] == architecture
          end
        end
        unless manifest && manifest.fetch("digest").match?(/\Asha256:[0-9a-f]{64}\z/)
          raise Error.new("release_unavailable", "The release does not contain an image for the Docker platform.")
        end
        reference = "#{repository}@#{manifest.fetch("digest")}"
        # Read configuration through the frozen digest, never resolve the rolling tag twice.
        config = registry_json(reference, "{{json .Image}}", deadline)
        label = config.fetch("config").fetch("Labels", {})
        images << Image.new(name: product, reference: reference, version: label["org.opencontainers.image.version"])
        labels << label
      end
      versions = labels.map { |label| label["org.opencontainers.image.version"].to_s }.uniq
      unless versions.size == 1 && Release.valid_tag?(versions.first) && (tag == "latest" || versions.first == tag)
        raise Error.new("release_unavailable", "The selected images do not identify the same published release.")
      end
      revisions = labels.map { |label| label["org.opencontainers.image.revision"] }.uniq
      sources = labels.map { |label| label["org.opencontainers.image.source"] }.uniq
      Release.new(
        release: versions.first, images: images, checked_at: Time.now.utc.iso8601(6),
        source_revision: revisions.size == 1 ? revisions.first : nil, source_url: sources.size == 1 ? sources.first : nil,
      )
    rescue Error => error
      raise error if error.code == "release_unavailable"
      raise Error.new("release_unavailable", "Release metadata could not be read within the registry deadline.")
    rescue JSON::ParserError, KeyError
      raise Error.new("release_unavailable", "The registry returned incomplete image metadata.")
    end

    def preflight(tag, backup_directory:, scope: "installation", backup: true)
      products = self.class.products(scope)
      candidate = nil
      current = nil
      database_bytes = nil
      checks = []
      checks << inspect_check("Release images", "Verify the configured repositories and release tag, then check again.") do
        candidate = check(tag, scope: scope)
        "The selected native-platform images identify release #{candidate.release}; their digests are frozen."
      end
      checks << inspect_check("Installed images", "Start or repair the existing installation before upgrading.") do
        current = installed
        unless products.all? { |name| current.images.any? { |image| image.name == name } }
          raise Error.new("preflight_failed", "The installed application images could not be identified.")
        end
        "The selected installed images are recorded."
      end
      checks << inspect_check("Compose configuration", "Inspect ./cybros compose config and repair the installation configuration.") do
        run(compose + ["config", "--quiet"], timeout: 10, environment: candidate ? image_environment(candidate) : {})
        "The installation Compose configuration is valid."
      end
      checks << inspect_check("PostgreSQL", "Start or repair PostgreSQL; inspect ./cybros logs db, then check again.") do
        if backup
          database_bytes = database_size
          "PostgreSQL is reachable; application databases occupy #{database_bytes} bytes."
        else
          run(compose + ["exec", "-T", "db", "psql", "-U", "postgres", "-d", "postgres", "-At", "-c", "SELECT 1"], timeout: 10)
          "PostgreSQL is reachable."
        end
      end
      checks << backup_space_check(backup_directory, database_bytes) if backup
      checks << PreflightCheck.new(name: "Docker image storage", status: "warning",
        message: "Docker does not expose image-store free capacity through this check. Image pulls finish before application services stop.",
        next_step: "Check Docker Desktop disk usage or the Docker data-root filesystem before a large update.", available_bytes: nil, required_bytes: nil)
      Inspection.new(candidate: candidate, installed: current, preflight: Preflight.new(scope: scope, backup: backup, checked_at: Time.now.utc.iso8601(6), checks: checks))
    end

    def prepare(target, log:, backup: true)
      run(compose + ["config", "--quiet"], timeout: 10, environment: image_environment(target))
      ensure_backup_space if backup
      target.images.each do |image|
        log.call("Pulling #{image.name}: #{image.reference}\n")
        run(["pull", image.reference], timeout: 900, capture: false)
        document = image_details(image.reference)
        unless document.fetch("Config").fetch("Labels", {})["org.opencontainers.image.version"] == target.release
          raise Error.new("release_unavailable", "A pulled image does not identify the selected release.")
        end
        log.call("#{image.name}: selected image is available locally.\n")
      end
      # Docker images and installation backups may share a filesystem. Pulls
      # can consume the budget observed above, so recheck before services stop.
      ensure_backup_space if backup
    end

    def stop(log:, scope: "installation")
      services(self.class.products(scope)).each do |service|
        # Selected ingress and both workers stop before Nexus and before migration.
        log.call("Stopping #{service}.\n")
        run(compose + ["stop", "--timeout", "40", service], timeout: 50, capture: false)
        service_containers([service]).each do |container|
          state = container.fetch("State")
          if state.fetch("Running")
            raise Error.new("stop_failed", "An application service remained running after stop.")
          end
          if state["ExitCode"] == 137 || state["OOMKilled"]
            log.call("#{service}: forced termination observed (exit #{state["ExitCode"]}).\n")
          end
        end
      end
    end

    def dump_database(file)
      run(compose + ["exec", "-T", "db", "pg_dumpall", "-U", "postgres"], timeout: 1800, output_file: file)
    rescue Error
      raise Error.new("backup_failed", "The database export failed. Applications remain stopped; migration has not started.")
    end

    def assert_stopped(migrators:)
      containers = service_containers(SERVICES + %w[db migrator data_init])
      if containers.any? { |container| container.fetch("State").fetch("Running") }
        raise Error.new("backup_unavailable", "Stop the complete installation with ./cybros stop before backup or restore.")
      end
      migrators.each do |name|
        result = run(["inspect", name], timeout: 5, allow_failure: true)
        if result.exitstatus.zero? && JSON.parse(result.output).first.fetch("State").fetch("Running")
          raise Error.new("backup_unavailable", "A recorded migration is still running. Stop or reconcile it before backup or restore.")
        end
      end
    end

    def backup_images
      containers = service_containers(PRODUCTS + ["db"])
      arguments = ["compose", "--project-directory", @directory, "--env-file", File.join(@directory, ".env"), "-f", File.join(@directory, "updater.compose.yaml")]
      ids = run(arguments + ["ps", "--all", "--quiet", "updater"], timeout: 5).output.split
      unless ids.empty?
        containers.concat(JSON.parse(run(["inspect", *ids], timeout: 5).output).reject { |container| oneoff?(container) })
      end
      names = containers.map { |container| container.fetch("Config").fetch("Labels").fetch("com.docker.compose.service") }.sort
      unless names == %w[db nexus rho updater]
        raise Error.new("backup_unavailable", "A complete installed stack is required to record matching database, updater and application images.")
      end
      containers.map do |container|
        image = image_details(container.fetch("Image"))
        reference = image.fetch("RepoDigests", []).first || image.fetch("Id")
        labels = container.fetch("Config").fetch("Labels")
        Image.new(name: labels.fetch("com.docker.compose.service"), reference: reference, version: labels["org.opencontainers.image.version"])
      end
    end

    def available_bytes(directory)
      if File.exist?(directory) && !File.directory?(directory)
        raise Error.new("preflight_failed", "The backup destination is not a directory.")
      end
      directory = File.dirname(directory) unless File.directory?(directory)
      result = run(["-Pk", directory], executable: "df", timeout: 5, environment: { "LC_ALL" => "C" })
      Integer(result.output.lines.last.to_s.split.fetch(3)) * 1024
    rescue ArgumentError, IndexError
      raise Error.new("preflight_failed", "The filesystem free space could not be read.")
    end

    def migrate(target, name:, log:)
      # Keep this named container after exit so a restarted updater can observe the
      # one migration attempt without inferring success from its own receipt.
      log.call("Starting migration container #{name}. Full migration output remains in its Docker logs.\n")
      run(compose + ["run", "--no-deps", "--detach", "--name", name, "migrator"], timeout: 30, environment: image_environment(target), capture: false)
      await_migration(name, log: log)
    end

    def migration_succeeded?(name)
      document = inspect_container(name)
      state = document.fetch("State")
      state.fetch("Status") == "exited" && state.fetch("ExitCode") == 0
    end

    def activate(target, log:)
      environment = image_environment(target)
      log.call("Starting Nexus and its workers with the selected image.\n")
      run(compose + ["up", "-d", "--no-deps", "--wait", "--wait-timeout", @wait_timeout.to_s, "nexus", "jobs", "model_runner"],
        timeout: @wait_timeout + 30, environment: environment, capture: false)
      if target.images.any? { |image| image.name == "rho" }
        log.call("Starting rho with the selected image.\n")
        run(compose + ["up", "-d", "--no-deps", "--wait", "--wait-timeout", @wait_timeout.to_s, "rho"],
          timeout: @wait_timeout + 30, environment: environment, capture: false)
      end
    end

    def verify(target)
      expected = target.images.to_h { |image| [image.name, image_details(image.reference).fetch("Id")] }
      first = verify_containers(expected)
      sleep @worker_observation
      second = verify_containers(expected)
      unless first == second
        raise Error.new("readiness_failed", "An application process restarted during the readiness observation.")
      end
    end

    private

    def immutable_reference(container)
      reference = container.fetch("Config").fetch("Image")
      if reference.include?("@sha256:") || reference.start_with?("sha256:")
        reference
      else
        # A component left untouched by an upgrade must not follow a moving tag
        # when ordinary Compose startup later reads the saved image references.
        image = image_details(container.fetch("Image"))
        image.fetch("RepoDigests", []).first || image.fetch("Id")
      end
    end

    def services(products)
      products.include?("rho") ? SERVICES : %w[jobs model_runner nexus]
    end

    def ensure_backup_space
      space = backup_space_check(File.join(@directory, "backups"), database_size)
      if space.status == "blocked"
        raise Error.new("insufficient_space", space.message)
      end
    end

    def inspect_check(name, next_step)
      message = yield
      PreflightCheck.new(name: name, status: "passed", message: message, next_step: nil, available_bytes: nil, required_bytes: nil)
    rescue Error => error
      PreflightCheck.new(name: name, status: "blocked", message: error.message, next_step: next_step, available_bytes: nil, required_bytes: nil)
    end

    def database_size
      sql = "SELECT coalesce(sum(pg_database_size(oid)), 0) FROM pg_database WHERE NOT datistemplate"
      Integer(run(compose + ["exec", "-T", "db", "psql", "-U", "postgres", "-d", "postgres", "-At", "-c", sql], timeout: 10).output.strip)
    rescue ArgumentError
      raise Error.new("preflight_failed", "PostgreSQL returned an unreadable storage size.")
    end

    def backup_space_check(directory, database_bytes)
      available = available_bytes(directory)
      required = database_bytes && 2 * database_bytes + Backups::HEADROOM_BYTES
      ready = required && available >= required
      message = if required
        "#{available} bytes free; estimated backup budget #{required} bytes (twice database size plus 256 MiB). This estimate is not a space guarantee."
      else
        "The database backup budget cannot be estimated until PostgreSQL is reachable."
      end
      PreflightCheck.new(name: "Backup storage", status: ready ? "passed" : "blocked", message: message,
        next_step: ready ? nil : "Make PostgreSQL reachable and free space on the installation filesystem, then check again.", available_bytes: available, required_bytes: required)
    rescue Error => error
      PreflightCheck.new(name: "Backup storage", status: "blocked", message: error.message,
        next_step: "Check the installation backup directory and filesystem capacity, then check again.", available_bytes: nil, required_bytes: nil)
    end

    def compose
      arguments = ["compose", "--project-directory", @directory, "--env-file", File.join(@directory, ".env")]
      images_path = File.join(@directory, "images.env")
      arguments += ["--env-file", images_path] if File.exist?(images_path)
      arguments + ["--env-file", File.join(@directory, "secrets.env"), "-f", File.join(@directory, "compose.yaml"), "-f", File.join(@directory, "deployment.compose.yaml")]
    end

    def image_environment(target)
      target.images.to_h { |image| ["CYBROS_#{image.name.upcase}_IMAGE", image.reference] }
    end

    def service_containers(services)
      ids = run(compose + ["ps", "--all", "--quiet", *services], timeout: 5).output.split
      if ids.empty?
        []
      else
        JSON.parse(run(["inspect", *ids], timeout: 5).output).reject { |container| oneoff?(container) }
      end
    end

    # Compose stop/up manage services, not operator-owned compose run processes,
    # which ps --all also lists under the service name.
    def oneoff?(container) = container.fetch("Config").fetch("Labels")["com.docker.compose.oneoff"].to_s.downcase == "true"

    def image_details(reference)
      JSON.parse(run(["image", "inspect", reference], timeout: 5).output).fetch(0)
    end

    def inspect_container(name)
      JSON.parse(run(["inspect", name], timeout: 5).output).fetch(0)
    end

    def await_migration(name, log:)
      run(["wait", name], timeout: 1800)
      unless migration_succeeded?(name)
        raise Error.new("migration_failed", "The migration container did not exit successfully. Applications remain stopped.")
      end
      log.call("Migration container exited successfully.\n")
    end

    def verify_containers(expected)
      required_services = services(expected.keys)
      containers = service_containers(required_services)
      names = containers.map { |container| container.fetch("Config").fetch("Labels").fetch("com.docker.compose.service") }.sort
      unless names == required_services.sort
        raise Error.new("readiness_failed", "Not all required application services are present.")
      end
      containers.to_h do |container|
        name = container.fetch("Config").fetch("Labels").fetch("com.docker.compose.service")
        product = name == "rho" ? "rho" : "nexus"
        state = container.fetch("State")
        unless state.fetch("Running") && !state.fetch("Restarting") && container.fetch("Image") == expected.fetch(product)
          raise Error.new("readiness_failed", "An application service is not running the selected image.")
        end
        if PRODUCTS.include?(name) && state.fetch("Health", {})["Status"] != "healthy"
          raise Error.new("readiness_failed", "An application service did not become healthy.")
        end
        [name, [container.fetch("Id"), container.fetch("RestartCount"), state.fetch("StartedAt")]]
      end
    end

    def registry_json(reference, format, deadline)
      remaining = deadline - monotonic
      unless remaining.positive?
        raise Error.new("release_unavailable", "Release metadata exceeded the registry deadline.")
      end
      JSON.parse(run(["buildx", "imagetools", "inspect", reference, "--format", format], timeout: remaining).output)
    end

    def run(arguments, **options) = @command.run(arguments, **options)
    def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end
end
