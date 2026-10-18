module McpConnection::Authorization
  def authorization_status
    return "not_applicable" unless auth_type == "oauth"

    data = oauth_data
    return "not_authorized" if data.nil?
    return "reauthorization_required" if data.reauthorization_reason

    if data.operation
      return "reauthorization_required" unless oauth_operation_current?(data.operation)

      data.operation.kind == "refresh" ? "refreshing" : "pending"
    elsif data.pending_authorization
      oauth_pending_current?(data.pending_authorization) ? "pending" : "reauthorization_required"
    elsif data.tokens
      oauth_access_token_current? || data.tokens["refresh_token"].present? ? "authorized" : "reauthorization_required"
    else
      "not_authorized"
    end
  end

  def authorization_expires_at = auth_type == "oauth" ? oauth_data&.expires_at : nil

  def oauth_access_token_current?(now: Time.current)
    data = oauth_data
    data && data.reauthorization_reason.nil? && data.tokens.present? &&
      (data.expires_at.nil? || data.expires_at > now)
  end

  def current_bearer_token
    case auth_type
    when "none" then nil
    when "bearer" then bearer_token
    when "oauth" then oauth_access_token_current? ? oauth_data.tokens.fetch("access_token") : nil
    else raise "unknown MCP authentication kind"
    end
  end

  def begin_oauth_authorization(expected_lock_version:, redirect_uri:, now: Time.current)
    with_oauth_authority do
      if lock_version != expected_lock_version
        oauth_result(:stale_object)
      else
        data = McpConnection::OAuthData.new(
          redirect_uri: redirect_uri,
          client_information: oauth_data&.redirect_uri == redirect_uri ? oauth_data.client_information : nil
        )
        data.operation = oauth_operation("start", now: now)
        write_oauth_data(data)
        oauth_result(:saved)
      end
    end
  end

  def claim_oauth_callback(state:, now: Time.current)
    with_oauth_authority do
      data = oauth_data
      pending = data&.pending_authorization
      if pending.nil? || !oauth_state_matches?(pending.state, state)
        oauth_result(:authorization_failed)
      elsif !oauth_pending_current?(pending, now: now)
        interrupt_oauth("authority_changed")
      elsif data.operation
        oauth_operation_current?(data.operation, now: now) ? oauth_result(:authorization_pending) : interrupt_oauth("interrupted")
      else
        # Preserve the authority captured before the browser left Nexus.
        data.operation = oauth_operation("finish", now: now,
          owner_authority_generation: pending.owner_authority_generation)
        write_oauth_data(data)
        oauth_result(:saved)
      end
    end
  end

  def prepare_oauth_credential(now: Time.current)
    with_oauth_authority do
      data = oauth_data
      if data&.operation
        oauth_operation_current?(data.operation, now: now) ? oauth_result(:authorization_pending) : interrupt_oauth("interrupted")
      elsif data&.pending_authorization
        oauth_pending_current?(data.pending_authorization, now: now) ? oauth_result(:authorization_pending) : interrupt_oauth("expired")
      elsif data.nil? || data.tokens.nil?
        oauth_result(data&.reauthorization_reason ? :reauthorization_required : :missing_credential)
      elsif data.reauthorization_reason
        oauth_result(:reauthorization_required)
      elsif oauth_access_token_current?(now: now)
        oauth_result(:saved)
      elsif data.tokens["refresh_token"].blank?
        interrupt_oauth("expired")
      else
        data.operation = oauth_operation("refresh", now: now)
        write_oauth_data(data)
        oauth_result(:refresh_required)
      end
    end
  end

  def consume_oauth_pending(operation_id:, state:)
    consumed = nil
    with_oauth_authority do
      data = oauth_data
      pending = data&.pending_authorization
      if data&.operation&.id == operation_id && oauth_operation_current?(data.operation) &&
          pending && oauth_state_matches?(pending.state, state) && oauth_pending_current?(pending)
        consumed = pending.envelope
        data.pending_authorization = nil
        write_oauth_data(data)
      end
      oauth_result(:saved)
    end
    consumed
  end

  def complete_oauth_operation(operation_id:, data:, now: Time.current)
    with_oauth_authority do
      operation = oauth_data&.operation
      if operation&.id != operation_id
        oauth_result(:authorization_failed)
      elsif !oauth_operation_current?(operation, now: now)
        interrupt_oauth("interrupted")
      else
        data.operation = nil
        data.reauthorization_reason = nil
        write_oauth_data(data)
        oauth_result(:saved)
      end
    end
  end

  def fail_oauth_operation(operation_id:, reauthorization_required:)
    with_oauth_authority do
      if oauth_data&.operation&.id == operation_id
        if reauthorization_required
          interrupt_oauth("interrupted")
        else
          data = oauth_data
          data.operation = nil
          write_oauth_data(data)
          oauth_result(:authorization_failed)
        end
      else
        oauth_result(:authorization_failed)
      end
    end
  end

  def reject_oauth_credential(bearer_token:)
    return unless auth_type == "oauth"

    with_oauth_authority do
      if oauth_data&.operation.nil? && oauth_data&.tokens&.fetch("access_token", nil) == bearer_token
        interrupt_oauth("rejected")
      else
        oauth_result(:saved)
      end
    end
  end

  private

    # Management and token installation share the existing Human/connection
    # lane, so removal or disabling cannot be undone by a late HTTP response.
    def with_oauth_authority
      owner.with_lock do
        with_lock do
          if auth_type != "oauth"
            oauth_result(:credential_not_applicable)
          elsif !owner.active? || !enabled?
            oauth_result(:not_authorized)
          else
            yield
          end
        end
      end
    end

    def oauth_operation(kind, now:, owner_authority_generation: owner.authority_generation)
      McpConnection::OAuthData::Operation.new(id: SecureRandom.uuid_v7, kind: kind,
        deadline_at: now + McpConnection::OAuthData::OPERATION_SECONDS,
        owner_authority_generation: owner_authority_generation)
    end

    def oauth_operation_current?(operation, now: Time.current)
      operation.deadline_at > now && operation.owner_authority_generation == owner.authority_generation
    end

    def oauth_pending_current?(pending, now: Time.current)
      pending.expires_at > now && pending.owner_authority_generation == owner.authority_generation
    end

    def oauth_state_matches?(expected, supplied)
      ActiveSupport::SecurityUtils.secure_compare(expected, supplied)
    end

    def interrupt_oauth(reason)
      data = oauth_data || McpConnection::OAuthData.new
      data.tokens = nil
      data.expires_at = nil
      data.pending_authorization = nil
      data.operation = nil
      data.reauthorization_reason = reason
      write_oauth_data(data)
      oauth_result(:reauthorization_required)
    end

    # OAuth is internal connection state, not a competing configuration edit.
    # Keep the public version stable so a catalog refresh can rotate a token
    # and still apply under the management version its owner supplied.
    def write_oauth_data(data)
      self.oauth_data = data
      validate!
      update_columns(oauth_data: oauth_data, updated_at: Time.current)
    end

    def oauth_result(outcome) = McpConnection::Result.new(outcome: outcome, connection: self)
end
