module Rho
  class Environments
    # A side is born with the kernel's fork copy: the parent's tuple
    # under the side at once; the first read finds the side's own row.
    def remember_copy(conversation, binding, runner: @own_runner_public_id.call)
      remember(conversation, Record.new(public_id: nil, binding: binding, source: "parent"), runner:)
    end

    # THE TOP-DOWN COPY AT THE CHILD EDGE: for every child new to
    # the listing, the parent's tuple created on the CHILD's store —
    # anchor unchanged — `key_taken` done (the child's answerer or a
    # person wrote first, never overwritten). Future inputs capture this value.
    def adopt_children(parent, children)
      plane = @member_plane.call(host_public_id: parent)
      return if plane.nil?

      binding_targets(parent, plane:).each do |runner|
        binding = binding_for(parent, plane:, runner:)
        next if binding.nil?

        Array(children).each { |child| adopt_child(plane, child, binding, runner:) }
      end
    end

    private

      # THE UPWARD WALK: the projection's parent, up the chain
      # until a record or no parent; the child's copy written with the
      # parent's anchor (`key_taken` → done); a chain that cannot be seen
      # refuses authoring with `executor_environment_unavailable`.
      def walk(conversation, plane, run_public_id, depth = 0, parent: nil, runner:)
        parent ||= parent_of(conversation, plane)
        return nil if parent.nil?
        return unresolved(conversation, "the chain is deeper than #{WALK_DEPTH}") if depth >= WALK_DEPTH

        binding = parent_binding(parent, plane, run_public_id, depth, runner:)
        return nil if binding.nil?

        copy_record(plane, conversation, binding, runner:)
      end

      def parent_binding(parent, plane, run_public_id, depth, runner:)
        found = read_record(parent, plane, runner:) || walk(parent, plane, run_public_id, depth + 1, runner:)
        found&.binding
      end

      def parent_of(conversation, plane)
        projection_of(plane, conversation).parent&.public_id
      end

      def unresolved(conversation, detail)
        notice_once([:unresolved, conversation]) do
          @log&.warn("environment.unresolved", conversation: conversation, detail: detail)
        end
        raise CybrosAgent::Api::InvalidRequest.new(detail, code: "executor_environment_unavailable")
      end

      # A child's own row wins over inheritance in the memo and on the
      # runner, too. An unknown read must not publish a parent guess.
      def copy_record(plane, conversation, binding, runner:)
        copy = write_copy(plane, conversation, binding, runner:)
        if copy.nil?
          current = read_record(conversation, plane, runner:)
          return current if current
        end

        remember(conversation, Record.new(public_id: copy&.public_id, binding: binding, source: "parent"), runner:)
        Resolved.new(binding: binding, source: "parent", public_id: copy&.public_id,
          lock_version: copy&.lock_version, updated_at: copy&.updated_at)
      end

      # The child's copy on its own store; `key_taken` leaves the
      # existing row for copy_record to read, never overwritten.
      def write_copy(plane, conversation, binding, runner:)
        door(plane, conversation).create(namespace: Extensions::Environment::STORE_NAMESPACE,
          key: binding_key(runner), value: value_of(binding), idempotency_key: SecureRandom.uuid).store_entry
      rescue CybrosAgent::Api::Conflict => error
        raise unless error.code == "key_taken"

        nil
      rescue CybrosAgent::Api::Error, CybrosAgent::TransportError => error
        @log&.warn("environment.copy_failed", conversation: conversation, error_class: error.class.name,
          error: CybrosAgent::Redaction.call(error.message))
        nil
      end

      def adopt_child(plane, child, binding, runner:)
        copy_record(plane, child, binding, runner:)
      end
  end
end
