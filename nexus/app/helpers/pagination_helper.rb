module PaginationHelper
  PAGINATION_ITEM_CLASSES = "join-item btn btn-sm".freeze
  PAGINATION_CURRENT_ITEM_CLASSES = "#{PAGINATION_ITEM_CLASSES} btn-active cursor-default".freeze
  PAGINATION_DISABLED_ITEM_CLASSES = "#{PAGINATION_ITEM_CLASSES} btn-disabled".freeze

  def pagy_daisy_ui_nav(pagy, aria_label:)
    return if pagy.last <= 1 && pagy.page <= pagy.last

    items = [pagy_direction_item(pagy, :previous)]
    series = pagy.data_hash(data_keys: [:series]).fetch(:series)
    items.concat(series.map { |item| pagy_series_item(pagy, item) })
    items << pagy_direction_item(pagy, :next)

    tag.nav(class: "min-w-0 max-w-full overflow-x-auto", aria: { label: aria_label }) do
      tag.div(safe_join(items), class: "join")
    end
  end

  private

    def pagy_direction_item(pagy, direction)
      page, label, icon, rel = case direction
      when :previous
        [pagy.previous, Pagy::I18n.translate("pagy.aria_label.previous"), "lucide--chevron-left", "prev"]
      when :next
        [pagy.next, Pagy::I18n.translate("pagy.aria_label.next"), "lucide--chevron-right", "next"]
      else
        raise ArgumentError, "unknown pagination direction: #{direction.inspect}"
      end

      content = tag.span(class: "iconify #{icon} size-4", aria: { hidden: true })
      if page
        link_to(content, pagy.page_url(page), class: PAGINATION_ITEM_CLASSES, rel: rel, aria: { label: label })
      else
        tag.a(content, class: PAGINATION_DISABLED_ITEM_CLASSES, role: "link", aria: { disabled: true, label: label })
      end
    end

    def pagy_series_item(pagy, item)
      case item
      when Integer
        link_to(item.to_s, pagy.page_url(item), class: PAGINATION_ITEM_CLASSES)
      when String
        tag.span(
          item,
          class: PAGINATION_CURRENT_ITEM_CLASSES,
          aria: { current: "page" }
        )
      when :gap
        tag.span("…", class: PAGINATION_DISABLED_ITEM_CLASSES, role: "separator")
      else
        raise Pagy::InternalError,
          "expected pagination item to be an Integer, String, or :gap; got #{item.inspect}"
      end
    end
end
