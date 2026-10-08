require "minitest/autorun"
require "tmpdir"
require_relative "../lib/cybros_updater"

class UpdaterDockerTest < Minitest::Test
  class FakeCommand
    attr_accessor :versions, :restart_worker, :migration_exit, :fail_pull, :force_stop, :include_oneoff,
      :database_bytes, :disk_bytes, :disk_bytes_after_pull, :configuration_failed, :database_failed, :migration_running, :untagged_images
    attr_reader :calls, :containers

    def initialize(repositories)
      @repositories = repositories
      @versions = { "nexus" => "2610080750", "rho" => "2610080750" }
      @calls = []
      @containers = %w[nexus rho jobs model_runner db updater].to_h { |name| [name, container(name)] }
      @migration_exit = 0
      @verification_reads = 0
      @database_bytes = 1024 * 1024
      @disk_bytes = 1024 * 1024 * 1024
    end

    def run(arguments, **options)
      @calls << [arguments, options]
      if options[:executable] == "df"
        return CybrosUpdater::Command::Result.new(output: "Filesystem 1024-blocks Used Available Capacity Mounted on\nfixture 2097152 0 #{@disk_bytes / 1024} 0% /installation\n", exitstatus: 0)
      end
      output = case arguments.first
      when "version"
        "linux/arm64\n"
      when "buildx"
        registry(arguments)
      when "pull"
        if @fail_pull
          raise CybrosUpdater::Error.new("command_failed", "Injected pull failure.")
        end
        @disk_bytes = @disk_bytes_after_pull if @disk_bytes_after_pull
        "Private registry error: password=synthetic-deployment-secret\n"
      when "image"
        product = if arguments.last.start_with?("sha256:")
          name = @containers.find { |_name, document| document.fetch("Image") == arguments.last }.first
          %w[db updater rho].include?(name) ? name : "nexus"
        else
          product_for(arguments.last)
        end
        repository = @repositories.fetch(product, "registry.example/#{product}")
        image_id = arguments.last.start_with?("sha256:") ? arguments.last : config_id(product)
        digest = image_id == config_id(product) ? manifest_id(product) : installed_manifest_id(product)
        references = @untagged_images ? [] : ["#{repository}@#{digest}"]
        JSON.generate([{ "Id" => image_id, "RepoDigests" => references, "Config" => { "Labels" => { "org.opencontainers.image.version" => @versions.fetch(product, "2610080750") } } }])
      when "compose"
        compose(arguments, options)
      when "inspect"
        if arguments[1].start_with?("cybros-upgrade-")
          JSON.generate([{ "State" => { "Status" => @migration_running ? "running" : "exited", "Running" => !!@migration_running, "ExitCode" => @migration_exit } }])
        else
          names = arguments.drop(1).map { |id| id.delete_prefix("container-") }
          if names.include?("jobs") && @restart_worker
            @verification_reads += 1
            @containers.fetch("jobs")["RestartCount"] = @verification_reads
          end
          JSON.generate(names.map do |name|
            if name == "oneoff"
              container("nexus").tap { |document| document.fetch("Config").fetch("Labels")["com.docker.compose.oneoff"] = "True" }
            else
              @containers.fetch(name)
            end
          end)
        end
      when "wait"
        "#{@migration_exit}\n"
      else
        raise "Unexpected command: #{arguments.inspect}"
      end
      CybrosUpdater::Command::Result.new(output: output, exitstatus: 0)
    end

    def stop_all
      @containers.each_value { |document| document.fetch("State")["Running"] = false }
    end

    private

    def registry(arguments)
      product = product_for(arguments.fetch(3))
      if arguments.last == "{{json .Manifest}}"
        JSON.generate({ "digest" => "sha256:#{"0" * 64}", "manifests" => [
          { "digest" => "sha256:#{"f" * 64}", "platform" => { "os" => "unknown", "architecture" => "unknown" } },
          { "digest" => "sha256:#{"e" * 64}", "platform" => { "os" => "linux", "architecture" => "amd64" } },
          { "digest" => manifest_id(product), "platform" => { "os" => "linux", "architecture" => "arm64" } },
        ] })
      else
        JSON.generate({ "config" => { "Labels" => { "org.opencontainers.image.version" => @versions.fetch(product) } } })
      end
    end

    def compose(arguments, options)
      if arguments.include?("config")
        if @configuration_failed
          raise CybrosUpdater::Error.new("command_failed", "Configuration is invalid.")
        end
        ""
      elsif arguments.include?("psql")
        if @database_failed
          raise CybrosUpdater::Error.new("command_failed", "Database is unavailable.")
        end
        "#{@database_bytes}\n"
      elsif arguments.include?("pg_dumpall")
        options.fetch(:output_file).write("CREATE DATABASE preserved;\n")
        ""
      elsif (index = arguments.index("--quiet"))
        names = arguments.drop(index + 1).select { |name| @containers.key?(name) }
        names += ["oneoff"] if @include_oneoff && names.include?("nexus")
        names.map { |name| "container-#{name}\n" }.join
      elsif arguments.include?("stop")
        state = @containers.fetch(arguments.last).fetch("State")
        state["Running"] = false
        state["ExitCode"] = @force_stop ? 137 : 0
        ""
      elsif arguments.include?("run")
        "migration-container\n"
      elsif (index = arguments.index("--wait-timeout"))
        arguments.drop(index + 2).each do |name|
          product = name == "rho" ? "rho" : "nexus"
          @containers.fetch(name)["Image"] = config_id(product)
          @containers.fetch(name).fetch("Config")["Image"] = options.fetch(:environment).fetch("CYBROS_#{product.upcase}_IMAGE")
          @containers.fetch(name).fetch("Config").fetch("Labels")["org.opencontainers.image.version"] = @versions.fetch(product)
          @containers.fetch(name).fetch("State")["Running"] = true
        end
        ""
      else
        raise "Unexpected Compose call: #{arguments.inspect}"
      end
    end

    def product_for(reference)
      @repositories.find { |_name, repository| reference.start_with?("#{repository}@", "#{repository}:") }.first
    end

    def manifest_id(product) = "sha256:#{(product == "nexus" ? "a" : "b") * 64}"
    def installed_manifest_id(product) = "sha256:#{{ "nexus" => "1", "rho" => "2", "db" => "3", "updater" => "4" }.fetch(product) * 64}"
    def config_id(product) = "sha256:#{(product == "nexus" ? "c" : "d") * 64}"

    def container(name)
      product = name == "rho" ? "rho" : "nexus"
      old_image = { "rho" => "8", "db" => "7", "updater" => "6" }.fetch(name, "9")
      { "Id" => "container-#{name}", "Image" => "sha256:#{old_image * 64}", "RestartCount" => 0,
        "Config" => { "Image" => "#{@repositories.fetch(product)}:2610080748", "Labels" => { "com.docker.compose.service" => name, "org.opencontainers.image.version" => "2610080748" } },
        "State" => { "Running" => true, "Restarting" => false, "StartedAt" => "2026-10-08T00:00:00Z", "ExitCode" => 0, "Health" => { "Status" => "healthy" } } }
    end
  end

  def setup
    @directory = Dir.mktmpdir("install with spaces ")
    @repositories = { "nexus" => "ghcr.io/example/kernel", "rho" => "registry.example:5000/team/application" }
    @command = FakeCommand.new(@repositories)
    @docker = CybrosUpdater::Docker.new(directory: @directory, repositories: @repositories, command: @command, worker_observation: 0)
    @log = +""
    @logger = ->(text) { @log << text }
  end

  def teardown
    FileUtils.remove_entry(@directory)
  end

  def test_check_resolves_native_manifest_and_reads_config_only_from_fixed_references
    candidate = @docker.check("latest")
    assert_equal "2610080750", candidate.release
    assert_equal "ghcr.io/example/kernel@sha256:#{"a" * 64}", candidate.reference("nexus")
    assert_equal "registry.example:5000/team/application@sha256:#{"b" * 64}", candidate.reference("rho")
    metadata = @command.calls.map(&:first).select { |arguments| arguments.first == "buildx" }
    assert_equal 4, metadata.size
    assert_equal "ghcr.io/example/kernel:latest", metadata.first.fetch(3)
    assert_equal candidate.reference("nexus"), metadata.fetch(1).fetch(3)
    refute @command.calls.any? { |arguments, _options| arguments.first == "pull" }
  end

  def test_check_rejects_partial_latest_and_absent_release_labels
    @command.versions["rho"] = "2610080751"
    assert_equal "release_unavailable", assert_raises(CybrosUpdater::Error) { @docker.check("latest") }.code
    @command.versions = { "nexus" => nil, "rho" => nil }
    assert_equal "release_unavailable", assert_raises(CybrosUpdater::Error) { @docker.check("latest") }.code
    @command.versions = { "nexus" => "2610080750", "rho" => "2610080750" }
    assert_equal "release_unavailable", assert_raises(CybrosUpdater::Error) { @docker.check("2610080748") }.code
  end

  def test_nexus_upgrade_only_resolves_and_manages_nexus_while_rho_keeps_its_container_and_image
    @command.versions["rho"] = "another-independent-release"
    @command.containers.fetch("rho").fetch("State").fetch("Health")["Status"] = "unhealthy"
    previous_rho = JSON.parse(JSON.generate(@command.containers.fetch("rho")))
    candidate = @docker.check("latest", scope: "nexus")
    assert_equal %w[nexus], candidate.images.map(&:name)
    assert_equal "2610080750", candidate.images.first.version
    assert_equal %w[nexus], @docker.installed(scope: "nexus").images.map(&:name)
    assert_equal %w[nexus], @docker.sources(scope: "nexus").map(&:name)
    @docker.prepare(candidate, log: @logger)
    @docker.stop(log: @logger, scope: "nexus")
    @docker.migrate(candidate, name: "cybros-upgrade-#{SecureRandom.uuid_v7}", log: @logger)
    @docker.activate(candidate, log: @logger)
    @docker.verify(candidate)

    commands = @command.calls.map(&:first)
    assert_equal [candidate.reference("nexus")], commands.select { |arguments| arguments.first == "pull" }.map(&:last)
    assert_equal %w[jobs model_runner nexus], commands.select { |arguments| arguments.include?("stop") }.map(&:last)
    starts = commands.select { |arguments| arguments.include?("up") }
    assert_equal 1, starts.size
    assert_equal %w[nexus jobs model_runner], starts.first.last(3)
    refute_includes commands.flatten, "rho"
    refute_includes commands.flatten, "container-rho"
    refute commands.flatten.any? { |argument| argument.start_with?(@repositories.fetch("rho")) }
    refute @command.calls.any? { |_arguments, options| options.fetch(:environment, {}).key?("CYBROS_RHO_IMAGE") }
    assert_equal previous_rho, @command.containers.fetch("rho")
    @command.restart_worker = true
    assert_equal "readiness_failed", assert_raises(CybrosUpdater::Error) { @docker.verify(candidate) }.code
  end

  def test_mixed_installed_versions_retain_each_actual_image_and_do_not_claim_one_release
    @command.containers.fetch("rho").fetch("Config")["Image"] = "#{@repositories.fetch("rho")}:latest"
    before = @docker.installed
    assert_equal "2610080748", before.release
    assert_equal "#{@repositories.fetch("rho")}@sha256:#{"2" * 64}", before.reference("rho")

    target = @docker.check("latest", scope: "nexus")
    @docker.activate(target, log: @logger)
    current = @docker.installed
    assert_nil current.release
    assert_equal({ "nexus" => "2610080750", "rho" => "2610080748" }, current.images.to_h { |image| [image.name, image.version] })
    assert_equal before.reference("rho"), current.reference("rho")
    assert_equal target.reference("nexus"), current.reference("nexus")
    assert_equal "2610080750", @docker.installed(scope: "nexus").release
  end

  def test_installed_local_image_without_registry_digest_uses_its_actual_image_id
    @command.untagged_images = true
    current = @docker.installed
    current.images.each do |image|
      assert_equal @command.containers.fetch(image.name).fetch("Image"), image.reference
    end
  end

  def test_nexus_preflight_records_full_observation_without_requiring_a_rho_container_or_release
    @command.versions.delete("rho")
    inspected = @docker.preflight("latest", backup_directory: File.join(@directory, "backups"), scope: "nexus")
    assert inspected.preflight.ready?
    assert_equal "nexus", inspected.preflight.scope
    assert_equal %w[nexus rho], inspected.installed.images.map(&:name)
    assert_equal %w[nexus], inspected.candidate.images.map(&:name)

    @command.containers.delete("rho")
    inspected = @docker.preflight("latest", backup_directory: File.join(@directory, "backups"), scope: "nexus")
    assert inspected.preflight.ready?
    assert_equal %w[nexus], inspected.installed.images.map(&:name)
    metadata = @command.calls.map(&:first).select { |arguments| arguments.first == "buildx" }
    refute metadata.any? { |arguments| arguments.fetch(3).start_with?(@repositories.fetch("rho")) }
  end

  def test_check_accepts_calendar_release_labels_and_rejects_invalid_dates
    %w[0002292359 2402290000 9912312359].each do |tag|
      @command.versions = { "nexus" => tag, "rho" => tag }
      assert_equal tag, @docker.check(tag).release
    end

    %w[1791439200 20261008075000 2602290750 2610082400].each do |tag|
      @command.versions = { "nexus" => tag, "rho" => tag }
      error = assert_raises(CybrosUpdater::Error) { @docker.check("latest") }
      assert_equal "release_unavailable", error.code
    end
  end

  def test_upgrade_commands_preserve_paths_run_one_migrator_and_activate_without_dependencies
    candidate = @docker.check("latest")
    File.write(File.join(@directory, "images.env"), "# existing atomic image selection\n")
    @docker.prepare(candidate, log: @logger)
    @docker.stop(log: @logger)
    name = "cybros-upgrade-#{SecureRandom.uuid_v7}"
    @docker.migrate(candidate, name: name, log: @logger)
    @docker.activate(candidate, log: @logger)
    @docker.verify(candidate)
    commands = @command.calls.map(&:first)
    assert_equal [candidate.reference("nexus"), candidate.reference("rho")], commands.select { |arguments| arguments.first == "pull" }.map(&:last)
    stops = commands.select { |arguments| arguments.include?("stop") }
    assert_equal %w[rho jobs model_runner nexus], stops.map(&:last)
    migrations = commands.select { |arguments| arguments.include?("run") }
    assert_equal 1, migrations.size
    assert_includes migrations.first, "--no-deps"
    assert_includes migrations.first, name
    refute_includes migrations.first, "--rm"
    starts = commands.select { |arguments| arguments.include?("up") }
    assert_equal 2, starts.size
    starts.each { |arguments| assert_includes arguments, "--no-deps" }
    commands.select { |arguments| arguments.first == "compose" }.each do |arguments|
      assert_equal @directory, arguments.fetch(arguments.index("--project-directory") + 1)
      assert_includes arguments, File.join(@directory, "deployment.compose.yaml")
      env_files = arguments.each_index.filter_map { |index| arguments[index + 1] if arguments[index] == "--env-file" }
      assert_equal %w[.env images.env secrets.env].map { |name| File.join(@directory, name) }, env_files
    end
    refute commands.flatten.any? { |argument| argument.include?("db:reset") || argument == "down" }
  end

  def test_failed_migration_is_observed_without_automatic_restart
    target = @docker.check("latest")
    @command.migration_exit = 1
    name = "cybros-upgrade-#{SecureRandom.uuid_v7}"
    assert_equal "migration_failed", assert_raises(CybrosUpdater::Error) { @docker.migrate(target, name: name, log: @logger) }.code
    refute @docker.migration_succeeded?(name)
    assert_equal 1, @command.calls.count { |arguments, _options| arguments.include?("run") }
    assert_includes @log, "Full migration output remains in its Docker logs"
  end

  def test_worker_restart_fails_readiness_and_forced_stop_is_reported
    target = @docker.check("latest")
    @command.force_stop = true
    @docker.stop(log: @logger)
    assert_includes @log, "forced termination observed"
    @docker.activate(target, log: @logger)
    @command.restart_worker = true
    assert_equal "readiness_failed", assert_raises(CybrosUpdater::Error) { @docker.verify(target) }.code
  end

  def test_running_image_must_match_config_id_not_manifest_digest
    target = @docker.check("latest")
    assert_equal "readiness_failed", assert_raises(CybrosUpdater::Error) { @docker.verify(target) }.code
    @docker.activate(target, log: @logger)
    @docker.verify(target)
  end

  def test_private_command_output_is_not_forwarded_to_browser_logs
    target = @docker.check("latest")
    @docker.prepare(target, log: @logger)
    assert_includes @log, "Pulling nexus"
    refute_includes @log, "synthetic-deployment-secret"
    assert @command.calls.select { |arguments, _options| arguments.first == "pull" }.all? { |_arguments, options| options.fetch(:capture) == false }
  end

  def test_operator_oneoff_containers_are_not_managed_application_services
    @command.include_oneoff = true
    assert_equal 2, @docker.installed.images.size
    target = @docker.check("latest")
    @docker.stop(log: @logger)
    @docker.activate(target, log: @logger)
    @docker.verify(target)
  end

  def test_preflight_reports_fixed_image_identity_database_and_estimated_backup_space_without_pulling
    inspected = @docker.preflight("latest", backup_directory: File.join(@directory, "backups"))
    assert_equal "2610080750", inspected.candidate.release
    assert inspected.preflight.ready?
    check = inspected.preflight.checks.find { |entry| entry.name == "Backup storage" }
    assert_equal @command.disk_bytes, check.available_bytes
    assert_equal 2 * @command.database_bytes + CybrosUpdater::Backups::HEADROOM_BYTES, check.required_bytes
    assert_equal "warning", inspected.preflight.checks.find { |entry| entry.name == "Docker image storage" }.status
    refute @command.calls.any? { |arguments, _options| arguments.first == "pull" || arguments.include?("pg_dumpall") || arguments.include?("stop") }
  end

  def test_preflight_retains_a_resolved_candidate_and_actionable_blockers
    @command.configuration_failed = true
    @command.database_failed = true
    inspected = @docker.preflight("latest", backup_directory: File.join(@directory, "backups"))
    assert inspected.candidate
    refute inspected.preflight.ready?
    checks = inspected.preflight.checks.select { |entry| entry.status == "blocked" }
    assert_includes checks.map(&:name), "Compose configuration"
    assert_includes checks.map(&:name), "PostgreSQL"
    assert checks.all?(&:next_step)
  end

  def test_low_space_blocks_preflight_and_preparation_before_pull_or_stop
    @command.disk_bytes = 1024
    inspected = @docker.preflight("latest", backup_directory: File.join(@directory, "backups"))
    refute inspected.preflight.ready?
    error = assert_raises(CybrosUpdater::Error) { @docker.prepare(inspected.candidate, log: @logger) }
    assert_equal "insufficient_space", error.code
    refute @command.calls.any? { |arguments, _options| arguments.first == "pull" || arguments.include?("stop") }
  end

  def test_pulls_that_consume_the_backup_budget_refuse_preparation_before_stopping_services
    target = @docker.check("latest")
    @command.disk_bytes_after_pull = 1024
    error = assert_raises(CybrosUpdater::Error) { @docker.prepare(target, log: @logger) }
    assert_equal "insufficient_space", error.code
    assert_equal 2, @command.calls.count { |arguments, _options| arguments.first == "pull" }
    assert_equal 2, @command.calls.count { |_arguments, options| options[:executable] == "df" }
    refute @command.calls.any? { |arguments, _options| arguments.include?("stop") }
  end

  def test_snapshot_checks_ignore_operator_oneoffs_and_freeze_all_four_installed_images
    @command.stop_all
    @command.include_oneoff = true
    @docker.assert_stopped(migrators: ["cybros-upgrade-#{SecureRandom.uuid_v7}"])
    images = @docker.backup_images
    assert_equal %w[db nexus rho updater], images.map(&:name).sort
    assert images.all? { |image| image.reference.include?("@sha256:") }
    @command.migration_running = true
    assert_equal "backup_unavailable", assert_raises(CybrosUpdater::Error) { @docker.assert_stopped(migrators: ["cybros-upgrade-#{SecureRandom.uuid_v7}"]) }.code
  end

  def test_database_export_uses_a_file_sink_and_never_captures_sql
    File.open(File.join(@directory, "private.sql"), "w") { |file| @docker.dump_database(file) }
    assert_equal "CREATE DATABASE preserved;\n", File.read(File.join(@directory, "private.sql"))
    arguments, options = @command.calls.last
    assert_equal ["exec", "-T", "db", "pg_dumpall", "-U", "postgres"], arguments.last(6)
    assert options.fetch(:output_file)
  end
end
