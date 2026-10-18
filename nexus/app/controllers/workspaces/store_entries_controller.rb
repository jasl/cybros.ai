class Workspaces::StoreEntriesController < Workspaces::DataController
  before_action :load_entry, only: [:show, :edit, :update, :destroy]

  def index
    @namespace = params.permit(:namespace)[:namespace].to_s
    entries = workspace.store_entries
    entries = entries.where(namespace: @namespace) if @namespace.present?
    @entries_pagy, @entries = pagy(entries.order(:namespace, :key), limit: 25)
  end

  def show
  end

  def new
    @draft = { "namespace" => "", "key" => "", "value_json" => "null", "idempotency_key" => SecureRandom.uuid_v7 }
  end

  def edit
    @draft = { "value_json" => JSON.pretty_generate(@entry.value), "lock_version" => @entry.lock_version }
  end

  def create
    @draft = params.expect(store_entry: [:namespace, :key, :value_json, :idempotency_key]).to_h
    value = parse_value(template: :new)
    return if performed?

    key = @draft["idempotency_key"].to_s
    if key.blank? || key.bytesize > WorkspaceCommandReceipt::IDEMPOTENCY_KEY_MAX_BYTES
      return render_data_refusal(:invalid_idempotency_key, template: :new)
    end
    envelope = { "namespace" => @draft["namespace"].to_s, "key" => @draft["key"].to_s,
      "value" => value, "host_public_id" => workspace.public_id }
    outcome = workspace.store_create_receipts(acting_user: Current.user, idempotency_key: key,
      request_digest: WorkspaceCommandReceipt.digest_for(operation: :store_entry_create, envelope: envelope)).call do
      result = ::StoreEntries::Create.call(host: workspace, by: Current.user,
        namespace: envelope["namespace"], key: envelope["key"], value: value)
      if result.outcome == :created
        workspace.store_receipt_success(status: 201, body: { store_entry: AgentAPI::StoreEntryPresenter.full(result.entry) })
      else
        result
      end
    end
    case outcome.outcome
    when :executed
      created(outcome.response.body.fetch(:store_entry).fetch(:public_id), replayed: false)
    when :replayed
      created(outcome.receipt.response_body.fetch("store_entry").fetch("public_id"), replayed: true)
    when :mismatched
      render_data_refusal(:idempotency_envelope_mismatch, template: :new)
    when :refused
      render_store_refusal(outcome.refusal, template: :new)
    else
      raise "unmapped idempotent outcome: #{outcome.outcome}"
    end
  rescue Nexus::CanonicalJson::UnsupportedValue
    render_data_refusal(:unsupported_json, template: :new)
  end

  def update
    @draft = params.expect(store_entry: [:value_json, :lock_version]).to_h
    value = parse_value(template: :edit)
    version = parse_version(template: :edit) unless performed?
    return if performed?

    result = ::StoreEntries::Update.call(entry: @entry, by: Current.user, lock_version: version, value: value)
    if result.outcome == :updated
      redirect_to workspace_store_entry_path(workspace, @entry.public_id), notice: t("data_console.store.saved"), status: :see_other
    else
      render_store_refusal(result, template: :edit)
    end
  end

  def destroy
    @draft = params.expect(store_entry: [:lock_version]).to_h
    version = parse_version(template: :show)
    return if performed?

    result = ::StoreEntries::Delete.call(entry: @entry, by: Current.user, lock_version: version)
    if result.outcome == :deleted
      redirect_to workspace_store_entries_path(workspace), notice: t("data_console.store.deleted"), status: :see_other
    else
      render_store_refusal(result, template: :show)
    end
  end

  private

    def load_entry
      @entry = workspace.store_entries.find_by!(public_id: params.fetch(:public_id))
    end

    def parse_value(template:)
      JSON.parse(@draft["value_json"].to_s)
    rescue JSON::ParserError
      render_data_refusal(:invalid_json, template: template)
      nil
    end

    def parse_version(template:)
      version = Integer(@draft.fetch("lock_version").to_s, 10)
      raise ArgumentError unless (0..2_147_483_647).cover?(version)

      version
    rescue KeyError, ArgumentError
      render_data_refusal(:invalid_precondition, template: template)
      nil
    end

    def created(public_id, replayed:)
      response.set_header("Idempotency-Replayed", replayed.to_s)
      redirect_to workspace_store_entry_path(workspace, public_id), notice: t("data_console.store.saved"), status: :see_other
    end

    def render_store_refusal(result, template:)
      @validation_errors = result.errors&.full_messages
      @data_writable = workspace.reload.data_writable_by?(Current.user)
      render_data_refusal(result.outcome, template: template)
    end
end
