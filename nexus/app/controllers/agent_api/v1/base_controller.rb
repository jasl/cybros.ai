# Agent-family base: bearer-only, one bearer resolves to one plane, and a
# credential from the other plane is fenced with 401 rather than accepted
# with a degraded principal.
class AgentAPI::V1::BaseController < ActionController::API
  # No implicit root wrapping: a body
  # missing its documented typed root must fail the 400 the contract pins,
  # never be resurrected from model attribute names.
  wrap_parameters false

  include ActionController::HttpAuthentication::Token::ControllerMethods
  include APIErrors

  # Per caller per resource: keyed by the credential's public id, IP for the unauthenticated, a wider IP
  # backstop first. Resolved from a class attribute because a subclass `rate_limit` adds a callback under the
  # inherited one. Parallel agents share a credential; 6,000/min leaves room for
  # 32 workers each creating and reading one task per second on a resource.
  RATE_LIMIT = 6000
  RATE_LIMIT_WINDOW = 1.minute
  IP_BACKSTOP_MULTIPLIER = 100

  class_attribute :caller_rate_limit, instance_writer: false, default: RATE_LIMIT

  rate_limit to: -> { caller_rate_limit * IP_BACKSTOP_MULTIPLIER }, within: RATE_LIMIT_WINDOW,
    by: -> { "ip/#{request.remote_ip}" },
    name: "ip-backstop",
    with: -> { render_rate_limited(retry_after: RATE_LIMIT_WINDOW.to_i) }

  before_action :resume_agent_principal

  rate_limit to: :caller_rate_limit, within: RATE_LIMIT_WINDOW,
    by: -> { rate_limit_identity },
    name: "caller",
    with: -> { render_rate_limited(retry_after: RATE_LIMIT_WINDOW.to_i) }

  before_action :require_agent_authentication

  # THE ONE REFUSAL → STATUS MAP of the agent family: the service's
  # symbol is the wire code, absence conceals as the family's
  # `not_found`, the plane's conflicts are 409, its fences 403, and
  # everything else a service refuses crosses as an OPEN vocabulary at
  # 422. Both hosts' doors, the profile doors and the executor doors read
  # it through `render_refusal`; the pack's tables derive from it. A
  # family code (`stale_object`, `content_too_large`,
  # `idempotency_envelope_mismatch`) keeps errors.json's status wherever
  # it renders, so it needs no row here.
  ABSENCE_REFUSALS = %i[not_found already_tombstoned].freeze
  CONFLICT_REFUSALS = %i[
    conversation_archived subagent_follows_parent conversation_busy
    input_queue_full stale_context stale_timeline steering_target_changed
    variant_not_forkable steering_held queue_changed
    branch_required unsupported_turn_type variant_not_active variant_active
    apex_never_conceals not_terminal slot_occupied
    apex_only steering_holds run_live
    kernel_authored kernel_input_immutable
    run_settled conversation_hosted run_needs_attention execution_details_pruned
  ].freeze
  REFUSAL_STATUSES = {
    **CONFLICT_REFUSALS.index_with(:conflict),
    # A document that is not there, on the memory and prompt-document doors.
    memory_not_found: :not_found,
    prompt_document_not_found: :not_found,
    # The write fence, the owner's verbs, the dedication fence, the
    # profile door's one refusal.
    not_authorized: :forbidden,
    not_workspace_owner: :forbidden,
    workspace_agent_identifier_mismatch: :forbidden,
    not_agent: :forbidden,
    memory_read_only: :forbidden,
    # The doors' own conflicts: a host taking no writes, a lifecycle
    # transition under way, a store at its bound or its key, work not yet
    # terminal, and the compaction door's three.
    workspace_not_active: :conflict,
    transition_in_progress: :conflict,
    entry_limit_reached: :conflict,
    key_taken: :conflict,
    already_compacted: :conflict,
    task_not_queued: :conflict,
    compaction_disabled: :conflict,
    # The named definitions door's three: a paired program holds the
    # composed identifier, a removed row whose steward's generation moved,
    # the twin first PUT that lost on the unique index.
    identifier_taken: :conflict,
    shutdown_pending: :conflict,
    concurrent_write: :conflict,
    # The one 500 a door names: the summary row could not be created.
    arm_failed: :internal_server_error,
  }.freeze
  REFUSAL_DEFAULT_STATUS = :unprocessable_content
  # The symbol is the code on every door of this family.
  REFUSAL_CODES = {}.freeze
  # The sentence a person reads where `Refused: <code>` is not enough.
  REFUSAL_MESSAGES = {
    not_authorized: "This workspace is not writable by the caller",
    not_workspace_owner: "Only the active Human owner manages a workspace",
    workspace_agent_identifier_mismatch: "This workspace is dedicated to another agent",
    not_agent: "Only an Agent declares a configuration",
    identifier_taken: "This identifier is held by a paired program or another Human's definition",
    shutdown_pending: "The removed row cannot be restored: its steward's generation moved",
    concurrent_write: "Another request minted this row first; read it back and retry",
    workspace_not_active: "This workspace does not accept writes in its current state",
    stale_object: "The row changed since it was read; refetch and retry",
    idempotency_envelope_mismatch: "This Idempotency-Key was used with a different request",
    transition_in_progress: "Another lifecycle transition is in progress",
    target_not_eligible: "The transfer target is not an eligible active Human",
    invalid_access_mode: "Unsupported access mode",
    reserved_namespace: "A reserved kernel namespace cannot be served by a provider",
    provider_not_eligible:
      "The provider must be a live tools provider of this account that every member of this " \
      "workspace can reach — account-wide, or private to the owner of this private workspace",
    provider_incomplete: "The provider must announce every live tool of the namespace it overrides",
    conversation_archived: "This conversation is archived; unarchive it to write",
    entry_limit_reached: "This store already holds its maximum number of entries",
    key_taken: "This namespace and key already hold a value",
    not_terminal: "Only terminal work can be deleted; cancel it first",
    # A person who pressed the compaction button is owed the difference
    # between "already compacted", "nothing to compact" and "a reply is
    # running"; the automatic arm has one answer to all of them.
    conversation_busy: "A direct reply or a summary is running; compact once it settles",
    already_compacted: "The newest turn is already a summary",
    task_not_queued: "The running turn has no round left to compact before it is sent",
    compaction_disabled: "The turn's compaction policy is off",
    nothing_to_compact: "There is no history to compact",
    compaction_unavailable_under_raw: "The kernel assembles no history under raw; only a delegate can compact",
    arm_failed: "The summary could not be created",
    memory_not_found: "No such memory document",
    memory_read_only: "This memory binding does not permit writes",
    memory_scope_unavailable: "This memory scope is not available",
    memory_edit_invalid: "A nonempty old_text is required",
    memory_edit_not_found: "The text to replace was not found",
    memory_edit_ambiguous: "The text to replace occurs more than once",
    prompt_document_not_found: "No such prompt document",
    prompt_slot_unavailable: "The slot %{detail} is not held at this door",
    prompt_document_macro_unknown:
      "The macro {{%{detail}}} is outside the registry (#{Nexus::PromptMacros::REGISTRY.join(", ")})",
  }.freeze

  # Leaves declare their plane explicitly; there is no default, so a new
  # resource cannot silently inherit the wrong authorization boundary.
  class_attribute :credential_plane, instance_writer: false

  def self.serves_plane(plane)
    self.credential_plane = plane
  end

  private

    def require_agent_authentication
      render_unauthorized unless current_credential
    end

    def resume_agent_principal
      case credential_plane
      when :member then resume_member_credential
      when :executor_transport then resume_transport_credential
      else raise "controller declared no credential plane"
      end
    end

    def resume_member_credential
      authenticate_with_http_token do |raw, _options|
        # authenticate_token answers only for the member plane, so a platform
        # or transport credential fails here structurally.
        token = AccessToken.authenticate_token(raw)
        next if token.nil?

        Current.access_token = token
      end
    end

    def resume_transport_credential
      authenticate_with_http_token do |raw, _options|
        token = AccessToken.authenticate_executor_token(raw)
        next if token.nil?

        Current.access_token = token
      end
    end

    def current_credential
      Current.access_token
    end

    def rate_limit_identity
      if current_credential
        "credential/#{current_credential.public_id}"
      else
        "ip/#{request.remote_ip}"
      end
    end

    # A list's page size: the family default when absent, else a bounded
    # integer — "abc" is 400, never 0. Both planes page the same way.
    def limit_param(default:, max:)
      params[:limit].nil? ? default : bounded_integer(params[:limit], :limit, range: 1..max)
    end

    # The shared cursor reader: absent is the feed's start, and a cursor
    # that does not decode is present-but-malformed — the family's 400
    # `parameter_invalid`, on every plane alike.
    def cursor_param(codec, name)
      codec.decode(params[name])
    rescue Nexus::ReplayCursor::MalformedCursor
      raise APIErrors::ParameterInvalid, name
    end
end
