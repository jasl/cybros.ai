module McpConnection::Management
  # The Human lock serializes create/enable against remove's disable command.
  # The connection lock also orders current authority against tool start.
  def save_owned
    owner.with_lock do
      if !owner.active?
        McpConnection::Result.new(outcome: :not_authorized, connection: self)
      else
        McpConnection::Result.new(outcome: save ? :saved : :invalid, connection: self)
      end
    end
  end

  def revise(attributes:, expected_lock_version:)
    owner.with_lock do
      with_lock do
        if !owner.active?
          McpConnection::Result.new(outcome: :not_authorized, connection: self)
        elsif lock_version != expected_lock_version
          McpConnection::Result.new(outcome: :stale_object, connection: self)
        else
          assign_attributes(attributes)
          cancel_oauth_work if auth_type == "oauth" && !enabled?
          McpConnection::Result.new(outcome: save ? :saved : :invalid, connection: self)
        end
      end
    end
  end

  def set_credential(bearer_token:, expected_lock_version:)
    if auth_type == "oauth" && bearer_token.nil?
      revise(attributes: { oauth_data: nil }, expected_lock_version: expected_lock_version)
    elsif auth_type != "bearer"
      McpConnection::Result.new(outcome: :credential_not_applicable, connection: self)
    else
      revise(attributes: { bearer_token: bearer_token }, expected_lock_version: expected_lock_version)
    end
  end

  private

    def cancel_oauth_work
      data = oauth_data
      return if data.nil?

      # An in-flight refresh may already have spent the saved refresh token.
      # A later enable must not reuse it or accept its abandoned response.
      if data.operation&.kind == "refresh"
        data.tokens = nil
        data.expires_at = nil
        data.reauthorization_reason = "interrupted"
      end
      data.pending_authorization = nil
      data.operation = nil
      self.oauth_data = data
    end
end
