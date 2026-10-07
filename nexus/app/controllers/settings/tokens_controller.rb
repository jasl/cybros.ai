class Settings::TokensController < Settings::BaseController
  PAGE_SIZE = 10

  rate_limit to: 10, within: 3.minutes,
    by: -> { Current.user.public_id },
    scope: "settings/current-password",
    only: :create,
    with: -> { redirect_to settings_tokens_path, alert: t("settings.current_password_rate_limited") }

  def index
    @token_form = empty_token_form
    @current_password_errors = []
    load_tokens
  end

  # The reveal is the create response itself: only the digest is stored, so
  # the wire secret exists exactly once, here, under no-store.
  def create
    submitted = params.expect(token: [:current_password, :name, :note, :credential_plane])
    @token_form = token_form(submitted)
    @current_password_errors = []

    result = AccessTokens::Issue.call(
      user: Current.user,
      presented_session: Current.session,
      current_password: submitted[:current_password].to_s,
      name: @token_form.fetch(:name),
      note: @token_form.fetch(:note).presence,
      credential_plane: @token_form.fetch(:credential_plane)
    )

    case result.outcome
    when :issued
      no_store
      @token = result.token
      @secret = result.secret
      render :reveal, status: :created
    when :invalid_password
      @current_password_errors = invalid_password_errors
      render_invalid(result.token)
    when :not_issuable, :invalid
      render_invalid(result.token)
    else
      raise ArgumentError, "unknown access-token issuance outcome: #{result.outcome.inspect}"
    end
  end

  private

    def empty_token_form
      { name: "", note: "", credential_plane: "member" }
    end

    def token_form(submitted)
      {
        name: submitted[:name].to_s,
        note: submitted[:note].to_s,
        credential_plane: submitted[:credential_plane].presence || "member",
      }
    end

    def invalid_password_errors
      [
        I18n.t(
          "errors.format",
          attribute: Identity.human_attribute_name(:current_password),
          message: I18n.t("errors.messages.invalid")
        ),
      ]
    end

    def render_invalid(token)
      @invalid_token = token
      load_tokens
      flash.now[:alert] = t(".invalid")
      render :index, status: :unprocessable_entity
    end

    def load_tokens
      @tokens_pagy, @tokens = pagy(
        :offset,
        Current.user.access_tokens.order_by_recency,
        limit: PAGE_SIZE
      )
    end
end
