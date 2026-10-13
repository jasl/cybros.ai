# ONE FAMILY OVER THREE HOSTS: the bounded namespaced JSON store of a
# workspace, a conversation, or the acting principal's own row. The
# subclasses answer `find_store_host` and nothing else — reads on any
# browsable host, writes on a live one behind the dedication fence where the
# host is a workspace or a conversation, no fence on a person's own row;
# `value` is opaque JSON normalized once, so scalars and JSON null survive
# as themselves. The receipt is the host's (StoreHost): the profile host
# keeps none, so a retried create there is `key_taken`, never a replay.
class AgentAPI::V1::StoreEntriesController < AgentAPI::V1::Workspaces::BaseController
  def index
    host = find_store_host
    page = keyset_page(
      host.store_entries,
      columns: { namespace: :text, key: :text },
    )

    render json: {
      store_entries: page.records.map { |entry| AgentAPI::StoreEntryPresenter.basic(entry) },
      pagination: { next_after: page.next_after },
    }
  end

  def show
    entry = find_entry

    render json: { store_entry: AgentAPI::StoreEntryPresenter.full(entry) }
  end

  def create
    host = find_store_host
    key = required_idempotency_key
    return if performed?

    envelope = create_envelope(host)
    wrapper = host.store_create_receipts(
      acting_user: acting_user,
      idempotency_key: key,
      # Both receipt models compute the one canonical digest discipline;
      # the operation inside it fences a key across surfaces.
      request_digest: WorkspaceCommandReceipt.digest_for(operation: :store_entry_create, envelope: envelope),
    )

    if wrapper
      outcome = wrapper.call do
        result = create_entry(host, envelope)
        if result.outcome == :created
          host.store_receipt_success(
            status: 201,
            body: { store_entry: AgentAPI::StoreEntryPresenter.full(result.entry) },
          )
        else
          result
        end
      end
      render_idempotent_outcome(outcome)
    else
      # No receipt on this host: the create serializes on the host row, so
      # a repeat meets the committed duplicate as the friendly `key_taken`.
      render_store_entry_result(create_entry(host, envelope))
    end
  end

  def update
    entry = find_entry
    value = json_value_param(:store_entry, :value)
    fields = params.expect(store_entry: [:lock_version])
    lock_version = lock_version_from(fields)

    result = ::StoreEntries::Update.call(
      entry: entry, by: acting_user, lock_version: lock_version, value: value
    )
    render_store_entry_result(result)
  end

  def destroy
    entry = find_entry
    lock_version = bounded_integer(params[:lock_version], :lock_version, range: LOCK_VERSION_RANGE)

    result = ::StoreEntries::Delete.call(
      entry: entry, by: acting_user, lock_version: lock_version
    )
    render_store_entry_result(result)
  end

  private

    # The one thing a subclass answers: the browsable host the route names,
    # whose miss conceals like absence.
    def find_store_host
      raise NotImplementedError, "#{self.class} answers no store host"
    end

    def create_entry(host, envelope)
      ::StoreEntries::Create.call(
        host: host,
        by: acting_user,
        namespace: envelope["namespace"],
        key: envelope["key"],
        value: envelope["value"],
      )
    end

    # An entry under a non-reachable or wrong host reads as absence,
    # exactly like the host itself.
    def find_entry
      find_store_host.store_entries.find_by!(public_id: params.fetch(:public_id))
    end

    # namespace/key take the ordinary allowlist; `value` is the opaque
    # exception normalized once from Rails' parsed params, preserving presence
    # and JSON null. The digest additionally binds the host's identity.
    def create_envelope(host)
      value = json_value_param(:store_entry, :value)
      fields = params.expect(store_entry: [:namespace, :key])

      envelope = fields.to_h
      # `expect` requires only the root; absent (or permit-dropped
      # non-scalar) coordinates are this endpoint's required-field 400s,
      # exactly like the missing `value` above.
      %w[namespace key].each do |field|
        raise ActionController::ParameterMissing.new(field.to_sym) unless envelope.key?(field)
      end
      envelope["namespace"] = envelope["namespace"].to_s
      envelope["key"] = envelope["key"].to_s
      envelope["value"] = value
      envelope["host_public_id"] = host.public_id
      envelope
    end

    # The opaque value is read from the body (`value` required, JSON null legal);
    # a root that is not an object is a missing root.
    def json_value_param(root, key)
      container = request.request_parameters.fetch(root.to_s) { raise ActionController::ParameterMissing.new(root) }
      case container
      when Hash then container.fetch(key.to_s) { raise ActionController::ParameterMissing.new(key) }.deep_dup
      else raise ActionController::ParameterMissing.new(root)
      end
    end

    def render_store_entry_result(result)
      case result.outcome
      when :created
        render json: { store_entry: AgentAPI::StoreEntryPresenter.full(result.entry) }, status: :created
      when :updated
        render json: { store_entry: AgentAPI::StoreEntryPresenter.full(result.entry) }
      when :deleted
        head :no_content
      else
        render_refused(result)
      end
    end
end
