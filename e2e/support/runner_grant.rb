module E2E
  # THE BROWSER HALF OF A DEVICE GRANT: a person walks a pending device authorization through the
  # public connection page and clicks Connect. The runner branch is the one every harness executor
  # needs — `nexus_operator` mints no runner, so a transport credential exists only through this
  # ceremony — and it was private to the device-connection journey until a second caller
  # (`E2E::ExecutorProcess`) needed it.
  #
  # Two steps, so a journey can substitute its own stricter visit: `visit_connection`
  # brings the page to the connection screen; `connect_in_browser` scopes a
  # Runner and clicks Connect. The assertions are the session's own
  # (`assert_selector`/`assert_text`) — they wait the way the journeys'
  # `has_x?` reads did and raise where a journey would have failed.
  #
  # THE SCOPE BLOCK HAS THREE SHAPES (oauth/device_grants/show): a
  # registration that exists shows its scope as a badge and inherits it; a
  # new one offers the account-wide selector to an owner or administrator;
  # a new one connected by any other member is private to the Agents that member manages, and the page says so instead.
  #
  # TWO MACHINE KINDS, ONE BLOCK: a tools provider is a machine connection of another kind — the
  # page names it ("Connect tools provider", "This Tools provider will…") and offers the runner's
  # scope block unchanged, because a provider's admission IS the runner's ACL. The words come from
  # `authorization.executor_kind`; the branch is only the credential's shape.
  module RunnerGrant
    # The page's word for what is connecting, by the kind the request named.
    SUBJECTS = {
      "runner" => "runner", "tool_provider" => "tools provider", "agent_application" => "agent program",
    }.freeze
    # The capitalised machine word in the scope copy.
    MACHINE_LABELS = { "runner" => "Runner", "tool_provider" => "Tools provider" }.freeze
    INHERITED_COPY = "Assignment scope:".freeze
    # The selector's label and the private-only sentence, by the machine
    # word each carries (oauth/device_grants/show).
    SCOPE_CHECKBOXES = SUBJECTS.slice(*MACHINE_LABELS.keys)
      .transform_values { |word| "Make this #{word} available account-wide" }.freeze
    PRIVATE_ONLY_COPIES = MACHINE_LABELS
      .transform_values { |label| "This #{label} will be private to the Agents you manage." }.freeze
    # Any of the three shapes, for either machine kind: one wait for the
    # page to settle, then reads that do not wait (a heading can match
    # before Turbo swapped the page).
    SCOPE_SHAPES = Regexp.union(*SCOPE_CHECKBOXES.values, *PRIVATE_ONLY_COPIES.values, INHERITED_COPY)

    module_function

    def subject(authorization) = SUBJECTS.fetch(authorization.executor_kind)

    def scope_checkbox(kind) = SCOPE_CHECKBOXES.fetch(kind)

    def private_only_copy(kind) = PRIVATE_ONLY_COPIES.fetch(kind)

    # The connection page for one authorization, through the code form:
    # the code is pre-filled from the complete URI and the person continues.
    def visit_connection(actor:, authorization:)
      page = actor.page
      actor.visit(authorization.verification_uri_complete)
      page.assert_selector(:field, "Device code", with: authorization.user_code)

      page.click_button "Continue"
      page.assert_text("Connect #{subject(authorization)}")
      page.assert_text(authorization.user_code)
    end

    # What the page offers a machine grant, read after `visit_connection`:
    # `:selector` (a new registration, the person may choose account-wide),
    # `:private_only` (a new registration by a member who cannot), or the
    # scope an existing registration inherits — `:account_wide` or
    # `:user_private`. A caller that cannot know whether a sibling
    # connected the same key earlier reads this instead of guessing.
    def scope_offer(actor)
      page = actor.page
      page.assert_text(SCOPE_SHAPES)
      return :selector if MACHINE_LABELS.keys.any? { |kind| page.has_field?(scope_checkbox(kind), wait: 0) }
      return :private_only if MACHINE_LABELS.keys.any? { |kind| page.has_text?(private_only_copy(kind), wait: 0) }

      page.find("span.badge", text: /\A(Account-wide|Private)\z/).text == "Account-wide" ? :account_wide : :user_private
    end

    def connect_in_browser(actor:, authorization:, account_wide: false, existing_runner_scope: nil)
      page = actor.page
      kind = authorization.executor_kind
      if authorization.branch == :runner
        configure_runner_scope(
          page, kind,
          account_wide: account_wide,
          existing_runner_scope: existing_runner_scope
        )
      elsif account_wide || existing_runner_scope
        raise ArgumentError, "only a machine connection has an assignment scope"
      else
        MACHINE_LABELS.each_key { |machine| page.assert_no_selector(:field, scope_checkbox(machine)) }
      end

      page.assert_selector(:button, "Connect")
      page.assert_selector(:button, "Cancel")
      page.click_button "Connect"
      page.assert_text("Connection ready. Waiting for the #{subject(authorization)} to finish connecting.")
      if authorization.branch == :runner
        scope_copy = account_wide || existing_runner_scope == :account_wide ?
          "This #{MACHINE_LABELS.fetch(kind)} will be available account-wide for authorized discovery and new work" :
          "This #{MACHINE_LABELS.fetch(kind)} will be private to Agents managed by the member who connected it"
        page.assert_text(scope_copy)
      end
    end

    def configure_runner_scope(page, kind, account_wide:, existing_runner_scope:)
      page.assert_text(SCOPE_SHAPES)
      checkbox = scope_checkbox(kind)
      if existing_runner_scope
        expected_badge = case existing_runner_scope
        when :user_private then "Private"
        when :account_wide then "Account-wide"
        else raise ArgumentError, "unknown existing machine scope: #{existing_runner_scope.inspect}"
        end
        if account_wide
          raise ArgumentError, "a reconnect cannot select a new machine scope"
        end

        page.assert_no_selector(:field, checkbox)
        page.assert_text(INHERITED_COPY)
        page.assert_text(expected_badge)
        page.assert_text("Reconnecting keeps this registration's existing scope.")
      elsif page.has_field?(checkbox, wait: 0)
        page.assert_selector(:field, checkbox, unchecked: true)
        page.check(checkbox) if account_wide
      else
        raise ArgumentError, "only an owner or administrator can select account-wide" if account_wide

        page.assert_text(private_only_copy(kind))
      end
    end
  end
end
