module ApplicationHelper
  EXPLICIT_THEMES = %w[light dark].freeze

  # The theme cookie is client-written UI state; anything but the two explicit
  # themes means "system" and renders no data-theme attribute.
  def explicit_theme
    value = cookies[:theme]
    value if EXPLICIT_THEMES.include?(value)
  end

  # A status badge: the tone when `on`, the ghost badge otherwise.
  def badge_classes(on, tone:, extra: nil)
    class_names("badge badge-sm", extra, on ? "badge-#{tone} badge-soft" : "badge-ghost")
  end

  def member_display_name(user)
    user.display_name
  end

  def external_url_options
    Rails.application.routes.default_url_options.presence || {
      host: request.host,
      protocol: request.protocol,
      port: request.port,
    }
  end

  # Field-level validation messages under an input (console-wide convention,
  # fixed by the setup page). Deliberately not
  # daisyUI's validator-hint class: that one hides itself until the input is
  # :user-invalid, while these are server-rendered errors that must show.
  def validator_hints(messages, id: nil)
    return "" if messages.empty?

    content_tag(:div, id: id) do
      safe_join(messages.map do |message|
        content_tag(:p, message, class: "field-error mt-1 text-xs text-error")
      end)
    end
  end

  # One call renders an input bound to its validation messages: the error
  # styling, aria-invalid, and the aria-describedby linkage to the hint list
  # share one id derived from the field, so the pieces cannot drift apart.
  def validated_field(form, type, method, messages, size: nil, **options)
    hint_id = form.field_id(method, :errors)

    field = form.public_send(
      type, method,
      class: class_names("input w-full", "input-sm": size == :sm, "input-error": messages.any?),
      aria: { invalid: messages.any?.to_s, describedby: (hint_id if messages.any?) },
      **options
    )
    field + validator_hints(messages, id: hint_id)
  end
end
