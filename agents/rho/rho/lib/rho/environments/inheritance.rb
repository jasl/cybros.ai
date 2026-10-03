module Rho
  class Environments
    # A side is born with the kernel's fork copy: the parent's tuple
    # under the side at once; the first read finds the side's own row.
    def remember_copy(conversation, binding)
      remember(conversation, Record.new(public_id: nil, binding: binding, source: "parent"))
    end

    # THE TOP-DOWN COPY AT THE CHILD EDGE: for every child new to
    # the listing, the parent's tuple created on the CHILD's store —
    # anchor unchanged — `key_taken` done (the child's answerer or a
    # person wrote first, never overwritten); a child on a runner
    # elsewhere is relayed, not waited for.
    def adopt_children(parent, children)
      plane = @member_plane.call(host_public_id: parent)
      return if plane.nil?

      binding = binding_for(parent, plane: plane)
      return if binding.nil?

      Array(children).each { |child| adopt_child(plane, child, binding) }
    end

    private

      # THE UPWARD WALK: the projection's parent, up the chain
      # until a record or no parent; the child's copy written with the
      # parent's anchor (`key_taken` → done); a chain that cannot be seen
      # falls to zero with `environment.unresolved`.
      def walk(conversation, plane, loop, depth = 0, parent: nil)
        parent ||= parent_of(conversation, plane)
        return nil if parent.nil?
        return unresolved(conversation, "the chain is deeper than #{WALK_DEPTH}") if depth >= WALK_DEPTH

        binding =
          begin
            parent_binding(parent, plane, loop, depth)
          rescue Unreadable
            unresolved(conversation, "the parent #{parent}'s record cannot be read")
          end
        return nil if binding.nil?

        copy_record(plane, conversation, binding)
      end

      def parent_binding(parent, plane, loop, depth)
        memo = memo(parent)
        return memo.binding if memo in Record

        found = read_record(parent, plane) || walk(parent, plane, loop, depth + 1)
        found&.binding
      end

      def parent_of(conversation, plane)
        projection_of(plane, conversation).parent&.public_id
      rescue CybrosAgent::Api::Error, CybrosAgent::TransportError => error
        unresolved(conversation, "the parent cannot be read (#{error.class.name})")
      end

      def unresolved(conversation, detail)
        notice_once([:unresolved, conversation]) do
          @log&.warn("environment.unresolved", conversation: conversation, detail: detail)
        end
        nil
      end

      # A child's own row wins over inheritance in the memo and on the
      # runner, too. An unknown read must not publish a parent guess.
      def copy_record(plane, conversation, binding)
        copy = write_copy(plane, conversation, binding)
        if copy.nil?
          current = read_record(conversation, plane)
          return current if current
        end

        remember(conversation, Record.new(public_id: copy&.public_id, binding: binding, source: "parent"))
        Resolved.new(binding: binding, source: "parent", public_id: copy&.public_id,
          lock_version: copy&.lock_version, updated_at: copy&.updated_at)
      end

      # The child's copy on its own store; `key_taken` leaves the
      # existing row for copy_record to read, never overwritten.
      def write_copy(plane, conversation, binding)
        door(plane, conversation).create(namespace: Extensions::Environment::STORE_NAMESPACE,
          key: Extensions::Environment::STORE_KEY, value: value_of(binding), idempotency_key: SecureRandom.uuid)
      rescue CybrosAgent::Api::Conflict => error
        raise unless error.code == "key_taken"

        nil
      rescue CybrosAgent::Api::Error, CybrosAgent::TransportError => error
        @log&.warn("environment.copy_failed", conversation: conversation, error_class: error.class.name,
          error: CybrosAgent::Redaction.call(error.message))
        nil
      end

      def adopt_child(plane, child, binding)
        record = copy_record(plane, child, binding)
        runner = runner_of(plane, child)
        return if runner.nil? || @own_runner.call(runner)

        assert_remote(child, runner, record.binding, plane: plane, wait: false)
      end

      def runner_of(plane, conversation)
        projection_of(plane, conversation).runner&.executor_public_id
      rescue CybrosAgent::Api::Error, CybrosAgent::TransportError
        nil
      end
  end
end
