#!/usr/bin/env ruby
require_relative "lib/cybros_updater"

module CybrosUpdater
  class CLI
    def initialize(arguments, environment: ENV, input: $stdin, output: $stdout, errors: $stderr)
      @arguments = arguments
      @environment = environment
      @input = input
      @output = output
      @errors = errors
      @client = Client.new(environment.fetch("CYBROS_UPDATER_SOCKET", "/run/cybros-updater/updater.sock"))
    end

    def run
      action = @arguments.shift
      case action
      when "serve"
        serve
      when "request"
        bytes = @input.read(REQUEST_LIMIT + 1)
        if bytes.bytesize > REQUEST_LIMIT
          raise Error.new("invalid_request", "The deployment request exceeds its size limit.", status: 400)
        end
        result = @client.call(JSON.parse(bytes))
        @output.puts(JSON.generate(result))
        result.fetch("status") < 400 ? 0 : 1
      when "update"
        update(**release_options)
      when "check"
        print_data(request("check", release_options.transform_keys(&:to_s)))
      when "backup", "backups", "restore"
        maintenance(action)
      when "status"
        print_data(request("status"))
      when "receipt"
        id = @arguments.shift || last_id
        print_data(request("receipt", "operation_id" => id))
      when "log"
        id = @arguments.shift || last_id
        cursor = @arguments.shift
        print_data(request("log", "operation_id" => id, "cursor" => cursor))
      when "resume"
        operation = request("resume", "operation_id" => @arguments.shift)
        await_operation(operation)
      when "assert-idle"
        request("assert_idle")
        0
      when "refresh-installed"
        print_data(request("refresh_installed"))
      else
        @errors.puts("Usage: updater.rb serve | request | check [TAG] [--no-backup] | update [TAG] [--no-backup] | backup | backups | restore ID DIRECTORY | status | receipt [ID] | log [ID] [CURSOR] | resume ID | assert-idle | refresh-installed")
        2
      end
    rescue Error => error
      @errors.puts("#{error.code}: #{error.message}")
      1
    rescue JSON::ParserError
      @errors.puts("invalid_request: The deployment request is not valid JSON.")
      1
    rescue SystemCallError
      @errors.puts("updater_unavailable: A required installation file or local resource is unavailable. Check file ownership, permissions and free space.")
      1
    end

    private

    def serve
      directory = installation_directory
      keep = backup_keep
      store = installation_store(directory)
      engine = Engine.new(directory: directory, store: store, docker: docker(directory), backup_keep: keep)
      Server.new(engine: engine, socket_path: @environment.fetch("CYBROS_UPDATER_SOCKET", "/run/cybros-updater/updater.sock")).run
      0
    ensure
      store&.close
    end

    def installation_directory
      directory = @environment.fetch("CYBROS_INSTALL_DIR", "")
      unless directory.start_with?("/") && File.directory?(directory)
        raise Error.new("updater_unavailable", "CYBROS_INSTALL_DIR must be the existing absolute installation path.")
      end
      directory
    end

    def installation_store(directory)
      Store.new(@environment.fetch("CYBROS_UPDATER_STATE_DIR", File.join(directory, "data", "updater")))
    end

    def docker(directory)
      repositories = {
        "nexus" => repository("CYBROS_NEXUS_IMAGE_REPOSITORY", "jasl123/cybros-nexus"),
        "rho" => repository("CYBROS_RHO_IMAGE_REPOSITORY", "jasl123/cybros-rho"),
      }
      Docker.new(directory: directory, repositories: repositories)
    end

    def backup_keep
      value = @environment.fetch("CYBROS_BACKUP_KEEP", Backups::DEFAULT_KEEP.to_s)
      unless value.match?(/\A[1-9][0-9]*\z/)
        raise Error.new("updater_unavailable", "CYBROS_BACKUP_KEEP must be a positive integer.")
      end
      value.to_i
    end

    def maintenance(action)
      unless (action == "restore" && @arguments.size == 2 && @arguments.first.match?(UUID)) || (action != "restore" && @arguments.empty?)
        raise Error.new("invalid_request", "backup/backups take no arguments; restore requires a backup UUIDv7 and an empty absolute destination directory.", status: 400)
      end
      directory = installation_directory
      keep = backup_keep
      store = installation_store(directory)
      backups = Backups.new(directory: directory, store: store, keep: keep)
      result = case action
      when "backup" then backups.create(docker: docker(directory))
      when "backups" then backups.list
      else backups.restore(@arguments.fetch(0), destination: @arguments.fetch(1), docker: docker(directory))
      end
      print_data(result)
    ensure
      store&.close
    end

    def release_options
      backup = !@arguments.delete("--no-backup")
      unless @arguments.size <= 1 && (@arguments.empty? || @arguments.first == "latest" || Release.valid_tag?(@arguments.first))
        raise Error.new("invalid_request", "Choose latest or a UTC yyMMddHHmm tag, optionally followed by --no-backup.", status: 400)
      end
      { tag: @arguments.first || "latest", backup: backup }
    end

    def update(tag:, backup:)
      inspection = request("check", "tag" => tag, "backup" => backup)
      unless inspection.fetch("preflight").fetch("ready")
        print_data(inspection)
        raise Error.new("preflight_failed", "Resolve the blocked checks and run ./cybros check again.", status: 409)
      end
      candidate = inspection.fetch("candidate")
      operation = request("upgrade", "candidate" => candidate.slice("release", "images"), "idempotency_key" => SecureRandom.uuid_v7, "actor_public_id" => nil, "backup" => backup)
      await_operation(operation)
    end

    def repository(name, default)
      value = @environment.fetch(name, default)
      parts = value.split("/", -1)
      component = /\A[a-z0-9]+(?:(?:[._]|__|-+)[a-z0-9]+)*\z/
      host = /\A[a-z0-9]+(?:[.-][a-z0-9]+)*(?::[0-9]+)?\z/
      registry = parts.size > 1 && (parts.first.include?(".") || parts.first.include?(":") || parts.first == "localhost")
      valid = value.bytesize <= 255 && parts.each_with_index.all? { |part, index| part.match?(index.zero? && registry ? host : component) }
      unless valid && !value.empty?
        raise Error.new("updater_unavailable", "#{name} must be a Docker repository path without a tag, digest or URL scheme.")
      end
      value
    end

    def await_operation(operation)
      @output.puts("Upgrade #{operation.fetch("id")}")
      @output.flush
      cursor = nil
      loop do
        window = request("log", "operation_id" => operation.fetch("id"), "cursor" => cursor)
        window.fetch("entries").each { |entry| @output.print(entry.fetch("text")) }
        @output.flush
        cursor = window.fetch("next_cursor")
        operation = window.fetch("operation")
        caught_up = cursor == operation.fetch("log_cursor") || window.fetch("entries").empty?
        if operation.fetch("status") != "running" && caught_up
          if operation.fetch("status") == "succeeded"
            return 0
          else
            @errors.puts(operation.fetch("recovery"))
            return 1
          end
        end
        sleep 1 if caught_up
      end
    end

    def last_id
      operation = request("status").fetch("last_operation")
      unless operation
        raise Error.new("not_found", "No upgrade has been accepted.", status: 404)
      end
      operation.fetch("id")
    end

    def request(operation, attributes = {})
      result = @client.call(attributes.merge("operation" => operation))
      if result.fetch("status") >= 400
        error = result.fetch("error")
        raise Error.new(error.fetch("code"), error.fetch("message"), status: result.fetch("status"), operation_id: error["operation_id"])
      end
      result.fetch("data")
    end

    def print_data(data)
      @output.puts(JSON.pretty_generate(data))
      0
    end
  end
end

exit CybrosUpdater::CLI.new(ARGV).run if $PROGRAM_NAME == __FILE__
