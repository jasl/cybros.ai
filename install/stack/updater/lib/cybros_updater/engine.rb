module CybrosUpdater
  class Engine
    RECOVERY = "Applications or data may have changed. Inspect this receipt and the named migration container with ./cybros compose. Restore or repair the installation explicitly; an image change is not a database rollback."

    def initialize(directory:, store:, docker:, backup_keep: Backups::DEFAULT_KEEP)
      @directory = directory
      @store = store
      @docker = docker
      @backups = Backups.new(directory: directory, store: store, keep: backup_keep)
      @mutex = Mutex.new
      @checking = false
      @worker = nil
      document = store.load
      @installed = document["installed"] && Release.from_h(document.fetch("installed"))
      @candidate = document["candidate"] && Release.from_h(document.fetch("candidate"))
      @preflight = document["preflight"] && Preflight.from_h(document.fetch("preflight"))
      @receipts = document.fetch("receipts").map { |receipt| Receipt.from_h(receipt) }
      @receipts = @receipts.map do |receipt|
        if receipt.running?
          receipt.with(status: "interrupted", updated_at: timestamp, error: { "code" => "interrupted", "message" => "The updater stopped before completing this operation." }, recovery: RECOVERY)
        else
          receipt
        end
      end
      begin
        @installed = @docker.installed
      rescue Error
        # A stopped Docker daemon must not erase the last known installation.
        # Ordinary status remains a local read even while deployment is offline.
        nil
      end
      persist
    end

    def call(request)
      if @persistence_failed
        raise Error.new("updater_unavailable", "The updater could not persist its state. Restart it to reconcile the existing receipt.")
      end
      document = request.to_h
      scope = document.fetch("scope", "installation").to_s
      Docker.products(scope)
      case document.fetch("operation").to_s
      when "status"
        response(200, @mutex.synchronize { deployment(scope) })
      when "check"
        check(document.fetch("tag", "latest").to_s, scope, backup_choice(document))
      when "upgrade"
        accept(document, scope)
      when "receipt"
        id = valid_id(document.fetch("operation_id"))
        response(200, @mutex.synchronize { receipt_data(find_receipt(id, scope: scope)) })
      when "log"
        log(document, scope)
      when "resume"
        resume(valid_id(document.fetch("operation_id")), scope)
      when "assert_idle"
        @mutex.synchronize do
          ensure_idle(scope)
          response(200, { "allowed" => true })
        end
      when "refresh_installed"
        refresh_installed(scope)
      else
        raise Error.new("invalid_request", "Unknown deployment operation.", status: 400)
      end
    rescue Error => error
      { "status" => error.status, "error" => error.to_h }
    rescue KeyError, TypeError, NoMethodError, ArgumentError
      { "status" => 400, "error" => { "code" => "invalid_request", "message" => "The deployment request is invalid." } }
    end

    def wait
      @worker&.join
    end

    private

    def backup_choice(document)
      value = document.fetch("backup", true)
      unless [true, false].include?(value)
        raise Error.new("invalid_request", "Backup must be true or false.", status: 400)
      end
      value
    end

    def check(tag, scope, backup)
      unless tag == "latest" || Release.valid_tag?(tag)
        raise Error.new("invalid_request", "Choose latest or a valid UTC yyMMddHHmm release tag.", status: 400)
      end
      @mutex.synchronize do
        if @checking
          raise Error.new("updater_unavailable", "A release check is already running.")
        end
        @checking = true
      end
      begin
        inspected = @docker.preflight(tag, backup_directory: @backups.directory, scope: scope, backup: backup)
        @mutex.synchronize do
          @candidate = inspected.candidate
          @installed = inspected.installed || @installed
          @preflight = inspected.preflight.with(checks: inspected.preflight.checks + [upgrade_state_check])
          persist
          response(200, deployment(scope))
        end
      rescue Error
        @mutex.synchronize do
          @candidate = nil
          @preflight = nil
          persist
        end
        raise
      ensure
        @mutex.synchronize { @checking = false }
      end
    end

    def refresh_installed(scope)
      @mutex.synchronize { ensure_idle(scope) }
      installed = @docker.installed
      @mutex.synchronize do
        ensure_idle(scope)
        @installed = installed
        persist
        response(200, deployment(scope))
      end
    end

    def accept(document, scope)
      backup = backup_choice(document)
      key = valid_id(document.fetch("idempotency_key"))
      actor = document["actor_public_id"] && valid_id(document.fetch("actor_public_id"))
      selection = parse_selection(document.fetch("candidate"), scope)
      @mutex.synchronize do
        if (existing = @receipts.find { |receipt| receipt.idempotency_key == key })
          unless existing.actor_public_id == actor && existing.target.selection == selection && existing.backup == backup
            raise Error.new("idempotency_conflict", "This idempotency key already names a different upgrade.", status: 409, operation_id: visible_operation_id(existing, scope))
          end
          return response(202, receipt_data(existing))
        end
        ensure_idle(scope)
        unless @candidate && @candidate.selection == selection
          raise Error.new("candidate_changed", "Check the release again before selecting this upgrade.", status: 409)
        end
        unless @preflight&.ready? && @preflight.scope == scope && @preflight.backup == backup
          raise Error.new("preflight_failed", "Resolve the preflight blockers and check the release again before upgrading.", status: 409)
        end
        now = timestamp
        id = SecureRandom.uuid_v7
        receipt = Receipt.new(
          id: id, idempotency_key: key, actor_public_id: actor, target: @candidate, previous: project_release(@installed, Docker.products(scope)),
          phase: "accepted", status: "running", accepted_at: now, updated_at: now, completed_at: nil,
          error: nil, recovery: nil, log_cursor: nil, migrator_name: "cybros-upgrade-#{id}", database_backup: nil, backup: backup,
        )
        @receipts << receipt
        discarded = @receipts.shift([@receipts.size - Store::RECEIPT_LIMIT, 0].max)
        # Never start Docker work until acceptance has reached the installation disk.
        persist
        @store.prune(discarded.map(&:id))
        @worker = Thread.new { execute(id) }
        response(202, receipt_data(receipt))
      end
    end

    def parse_selection(value, scope)
      document = value.to_h
      release = document.fetch("release").to_s
      images = document.fetch("images").map do |entry|
        image = entry.to_h
        { "name" => image.fetch("name").to_s, "reference" => image.fetch("reference").to_s }
      end
      unless Release.valid_tag?(release) && images.map { |image| image.fetch("name") }.sort == Docker.products(scope).sort
        raise Error.new("invalid_request", "Select the complete checked release.", status: 400)
      end
      { "release" => release, "images" => images.sort_by { |image| image.fetch("name") } }
    end

    def ensure_idle(scope)
      if (active = @receipts.find(&:running?))
        raise Error.new("upgrade_in_progress", "An upgrade is already in progress.", status: 409, operation_id: visible_operation_id(active, scope))
      end
      if (interrupted = @receipts.reverse.find(&:needs_recovery?))
        raise Error.new("recovery_required", "An earlier upgrade requires explicit recovery.", status: 409, operation_id: visible_operation_id(interrupted, scope))
      end
    end

    def log(document, scope)
      id = valid_id(document.fetch("operation_id"))
      encoded = document.fetch("cursor", nil).to_s
      if encoded.bytesize > 64
        raise Error.new("invalid_request", "Invalid log cursor.", status: 400)
      end
      decoded = encoded.empty? ? "0" : Base64.strict_decode64(encoded)
      unless decoded.match?(/\A[0-9]{1,10}\z/)
        raise Error.new("invalid_request", "Invalid log cursor.", status: 400)
      end
      limit = Integer(document.fetch("limit", LOG_WINDOW_LIMIT))
      unless (1..LOG_WINDOW_LIMIT).cover?(limit)
        raise Error.new("invalid_request", "Invalid log window size.", status: 400)
      end
      @mutex.synchronize do
        receipt = find_receipt(id, scope: scope)
        response(200, @store.log(id, offset: Integer(decoded), limit: limit).merge("operation" => receipt_data(receipt)))
      end
    end

    def resume(id, scope)
      @mutex.synchronize do
        receipt = find_receipt(id, scope: scope)
        if (active = @receipts.find(&:running?))
          raise Error.new("upgrade_in_progress", "An upgrade is already in progress.", status: 409, operation_id: visible_operation_id(active, scope))
        end
        unless %w[failed interrupted].include?(receipt.status) && %w[stopping backing_up migrating activating verifying].include?(receipt.phase)
          raise Error.new("recovery_required", "This operation requires manual recovery or a new checked upgrade.", status: 409, operation_id: id)
        end
        # Once migration began, recovery never creates or restarts its container.
        # A missing, running or failed migration requires operator inspection.
        if receipt.phase == "migrating" && !@docker.migration_succeeded?(receipt.migrator_name)
          raise Error.new("recovery_required", "The existing migration has not proved a successful exit. Inspect it before recovery.", status: 409, operation_id: id)
        end
        receipt = receipt.with(status: "running", error: nil, recovery: nil, updated_at: timestamp, completed_at: nil)
        replace(receipt)
        persist
        @worker = Thread.new { execute(id, from_phase: receipt.phase) }
        response(202, receipt_data(receipt))
      end
    rescue Error => error
      raise error if error.status < 500
      raise Error.new("recovery_required", "The migration container could not be reconciled. Inspect it before recovery.", status: 409, operation_id: id)
    end

    def execute(id, from_phase: nil)
      receipt = @mutex.synchronize { find_receipt(id) }
      products = receipt.target.images.map(&:name)
      scope = products == Docker.products("nexus") ? "nexus" : "installation"
      logger = ->(text) { append_log(id, text) }
      unless %w[migrating activating verifying].include?(from_phase)
        unless from_phase == "backing_up"
          # A resumed stop may already have stopped some services. Keep that
          # recovery boundary if preparing the selected images fails again.
          unless from_phase == "stopping"
            transition(id, "preparing")
          end
          previous = @docker.installed
          @mutex.synchronize do
            @installed = previous
            replace(find_receipt(id).with(previous: project_release(previous, products)))
            persist
          end
          @docker.prepare(receipt.target, log: logger, backup: receipt.backup)
          transition(id, "stopping")
          @docker.stop(log: logger, scope: scope)
        end
        if receipt.backup
          transition(id, "backing_up")
          backup = @backups.database(id, docker: @docker)
          @mutex.synchronize do
            replace(find_receipt(id).with(database_backup: backup))
            persist
          end
          append_log(id, "Database backup saved privately (#{backup.size_bytes} bytes).\n")
        end
        transition(id, "migrating")
        @docker.migrate(receipt.target, name: receipt.migrator_name, log: logger)
      end
      transition(id, "activating")
      write_images(receipt.target)
      @docker.activate(receipt.target, log: logger)
      transition(id, "verifying")
      @docker.verify(receipt.target)
      installed = @docker.installed
      append_log(id, "Upgrade completed; the selected application services passed readiness.\n")
      @mutex.synchronize do
        current = find_receipt(id)
        @installed = installed
        replace(current.with(phase: "completed", status: "succeeded", updated_at: timestamp, completed_at: timestamp))
        persist
      end
    rescue Error => error
      record_failure(id, { "code" => error.code, "message" => error.message })
    rescue StandardError
      record_failure(id, { "code" => "updater_failed", "message" => "The updater could not complete the operation. Inspect its local diagnostics." })
    end

    def record_failure(id, failure)
      append_log(id, "#{failure.fetch("message")}\n")
      @mutex.synchronize do
        current = find_receipt(id)
        replace(current.with(status: "failed", error: failure, recovery: current.needs_recovery? ? RECOVERY : "The running deployment was retained. Check the release and retry explicitly.", updated_at: timestamp, completed_at: timestamp))
        persist
      end
    end

    def transition(id, phase)
      @mutex.synchronize do
        replace(find_receipt(id).with(phase: phase, updated_at: timestamp))
        persist
      end
      append_log(id, "#{phase}\n")
    end

    def append_log(id, text)
      @mutex.synchronize do
        cursor = @store.append_log(id, text)
        replace(find_receipt(id).with(log_cursor: cursor))
        persist
      end
    end

    def write_images(target)
      images = @mutex.synchronize { @installed.images.to_h { |image| [image.name, image.reference] } }
      target.images.each { |image| images[image.name] = image.reference }
      contents = images.sort.map { |name, reference| "CYBROS_#{name.upcase}_IMAGE='#{reference}'\n" }.join
      @store.atomic_write(File.join(@directory, "images.env"), contents, owner: File.stat(File.join(@directory, ".env")))
    end

    def deployment(scope)
      receipts = @receipts.select { |receipt| visible_release?(receipt.target, scope) }
      candidate = @candidate if @candidate && visible_release?(@candidate, scope)
      preflight = @preflight if scope == "installation" || @preflight&.scope == scope
      { "supported" => true, "sources" => @docker.sources(scope: scope).map(&:to_h), "installed" => project_release(@installed, Docker.products(scope))&.to_h, "candidate" => candidate&.to_h,
        "preflight" => preflight&.to_h, "active_operation" => receipt_data(receipts.find(&:running?)), "last_operation" => receipt_data(receipts.last) }
    end

    def project_release(release, products)
      if release
        images = release.images.select { |image| products.include?(image.name) }
        versions = images.map(&:version).uniq
        release.with(images: images, release: images.size == products.size && versions.size == 1 ? versions.first : nil)
      end
    end

    def visible_release?(release, scope)
      scope == "installation" || release.images.map(&:name).sort == Docker.products(scope).sort
    end

    def visible_operation_id(receipt, scope)
      receipt.id if visible_release?(receipt.target, scope)
    end

    def receipt_data(receipt)
      if receipt
        backup = receipt.database_backup
        backup = backup.with(available: @backups.available?(receipt.id)) if backup
        receipt.with(database_backup: backup).to_h
      end
    end

    def upgrade_state_check
      active = @receipts.find(&:running?)
      recovery = @receipts.reverse.find(&:needs_recovery?)
      message = if active
        "An upgrade is already in progress."
      elsif recovery
        "An earlier upgrade requires explicit recovery."
      else
        "No upgrade or unresolved recovery blocks this installation."
      end
      blocked = active || recovery
      PreflightCheck.new(name: "Upgrade state", status: blocked ? "blocked" : "passed", message: message,
        next_step: blocked ? "Inspect ./cybros upgrade-status and finish or recover that operation before checking again." : nil, available_bytes: nil, required_bytes: nil)
    end

    def replace(receipt)
      @receipts[@receipts.index { |entry| entry.id == receipt.id }] = receipt
    end

    def find_receipt(id, scope: "installation")
      @receipts.find { |receipt| receipt.id == id && visible_release?(receipt.target, scope) } || raise(Error.new("not_found", "The upgrade receipt is unavailable.", status: 404))
    end

    def persist
      @store.save(installed: @installed, candidate: @candidate, preflight: @preflight, receipts: @receipts)
    rescue IOError, SystemCallError
      @persistence_failed = true
      raise Error.new("updater_unavailable", "The updater could not persist its state. Restart it to reconcile the existing receipt.")
    end
    def response(status, data) = { "status" => status, "data" => data }
    def timestamp = Time.now.utc.iso8601(6)

    def valid_id(value)
      id = value.to_s
      unless id.bytesize == 36 && id.match?(UUID)
        raise Error.new("invalid_request", "A UUIDv7 identifier is required.", status: 400)
      end
      id
    end
  end
end
