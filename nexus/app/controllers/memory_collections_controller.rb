class MemoryCollectionsController < ApplicationController
  SEARCH_QUERY_MAX_LENGTH = 128

  before_action :load_collection, only: [:show, :edit, :update, :archive, :restore, :destroy]

  def index
    filters = params.permit(:query, :status, :scope)
    @query = filters.fetch(:query, "").to_s.strip[0, SEARCH_QUERY_MAX_LENGTH]
    @status = filters[:status].to_s.presence_in(%w[active archived all]) || "active"
    @scope = filters[:scope].to_s.presence_in(%w[user workspace conversation])&.to_sym
    @owner_parameters = owner_parameters
    @owner_scope = owner_scope
    @owner = owner if owner_selected?
    scope = collections.matching_name_or_id(@query,
      default_name: t("memory_collections.default_name"), unnamed_name: t("memory_collections.unnamed")).for_scope(@scope)
    scope = scope.where(archived_at: nil) if @status == "active"
    scope = scope.where.not(archived_at: nil) if @status == "archived"
    scope = owner.memory_collections.merge(scope) if owner_selected?
    @pagy, @collections = pagy(scope.order(:public_id), limit: 25)
    access.preload(@collections)
    @new_path = if owner_selected?
      new_memory_collection_path(owner_parameters) if access.owner_manageable?(owner, scope: owner_scope)
    else
      new_memory_collection_path
    end
  end

  def show
  end

  def new
    @owner_scope = owner_scope
    @owner = owner
    @draft = {}
    @create_path = memory_collections_path(owner_parameters)
    render_refusal(:not_authorized, template: :new) unless access.owner_manageable?(owner, scope: owner_scope)
  end

  def create
    @owner_scope = owner_scope
    @owner = owner
    @draft = params.expect(memory_collection: [:name, :description]).to_h
    @create_path = memory_collections_path(owner_parameters)
    result = MemoryCollections::Create.call(owner: owner, scope: owner_scope, by: Current.user,
      attributes: { name: @draft["name"], description: @draft["description"] })
    if result.accepted?
      redirect_to memory_collection_path(result.collection), notice: t("memory_collections.saved"), status: :see_other
    else
      render_result_failure(result, template: :new)
    end
  end

  def edit
    @draft = @collection.attributes.slice("name", "description", "lock_version")
    render_refusal(:not_authorized, template: :edit) unless @manageable
  end

  def update
    @draft = params.expect(memory_collection: [:name, :description, :lock_version]).to_h
    return render_refusal(:not_authorized, template: :edit) unless @manageable

    version = metadata_version(@draft, template: :edit)
    return if performed?

    result = access.with_management(@collection) do
      @collection.update_metadata(@draft.except("lock_version"), expected_lock_version: version)
    end
    if result.accepted?
      redirect_to memory_collection_path(@collection), notice: t("memory_collections.saved"), status: :see_other
    else
      render_result_failure(result, template: :edit)
    end
  end

  def archive = lifecycle(:archive)
  def restore = lifecycle(:restore)
  def destroy = lifecycle(:tombstone)

  private

    def access = @access ||= MemoryCollections::Access.new(by: Current.user)
    def collections = access.scope.includes(:workspace, :speaker, user: :derived_from, conversation: :workspace)
    def owner_selected? = params[:workspace_public_id].present? || params[:conversation_public_id].present?
    def owner_parameters = params.permit(:workspace_public_id, :conversation_public_id).to_h
    def owner_scope = params[:conversation_public_id].present? ? :conversation : params[:workspace_public_id].present? ? :workspace : :user

    def owner
      @owner ||= case owner_scope
      when :conversation then Conversation.visible_to(Current.user).find_by!(public_id: params[:conversation_public_id])
      when :workspace then Workspace.data_accessible_to(Current.user).browsable.find_by!(public_id: params[:workspace_public_id])
      when :user then Current.user
      else raise ArgumentError, "unknown memory owner"
      end
    end

    def load_collection
      @collection = collections.find_by!(public_id: params[:memory_collection_public_id] || params[:public_id])
      @manageable = access.manageable?(@collection)
      @data_writable = access.writable?(@collection)
    end

    def lifecycle(command)
      return render_refusal(:not_authorized, template: :show) unless @manageable

      version = metadata_version(params.expect(memory_collection: [:lock_version]), template: :show)
      return if performed?

      result = access.with_management(@collection) do
        @collection.public_send(command, expected_lock_version: version)
      end
      if result.accepted?
        redirect_to command == :tombstone ? memory_collections_path : memory_collection_path(@collection),
          notice: t("memory_collections.#{command}"), status: :see_other
      else
        render_result_failure(result, template: :show)
      end
    end

    def render_result_failure(result, template:)
      @error = result.errors.full_messages.to_sentence if result.outcome == :invalid
      render_refusal(result.outcome, template: template)
    end

    def metadata_version(fields, template:)
      value = Integer(fields[:lock_version].to_s, 10, exception: false)
      return value if value && MemoryDocuments::Precondition::VERSION_RANGE.cover?(value)

      render_refusal(:invalid_precondition, template: template)
      nil
    end

    def render_refusal(code, template:, status: nil, detail: nil)
      raise ActiveRecord::RecordNotFound if code == :not_found

      @error ||= t("data_console.errors.#{code}", detail: detail)
      @conflict = code == :stale_object
      status ||= Nexus::FamilyErrors.status_for(code) || (%i[not_authorized memory_read_only].include?(code) ? :forbidden : :unprocessable_entity)
      render template, status: status
    end
end
