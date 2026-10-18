module WorkReadingHelper
  def work_markdown(source)
    sanitize(Work::Markdown.render(source), scrubber: Work::MarkdownScrubber.new)
  rescue ArgumentError => error
    raise unless error.message == "Document tree depth limit exceeded"

    work_plain_text(source)
  rescue SystemStackError
    work_plain_text(source)
  end

  def work_original_text(source)
    # HTML normalizes literal CR bytes. Only this fixed character reference
    # is trusted; safe_join escapes every segment supplied by the author.
    safe_join(source.split("\r", -1), "&#13;".html_safe)
  end

  def captured_model_label(model)
    model&.provider_id.present? ? "#{model.provider_id}/#{model.model_ref}" : t("work_reading.unavailable")
  end

  def captured_configuration_facts(configuration, initial_model:, actual_model:, model_selection:, fallback_models:, approval_mode:, conversation_reach:)
    {
      t("work_reading.initial_model") => captured_model_label(initial_model),
      t("work_reading.actual_model") => captured_model_label(actual_model),
      t("work_reading.selection") => model_selection ? JSON.generate(ModelSelection::Projection.intent(model_selection)) : t("work_reading.unavailable"),
      t("work_reading.tools") => captured_tools_label(configuration),
      t("work_reading.approval") => approval_mode.presence || t("work_reading.unavailable"),
      t("work_reading.memory") => captured_memory_label(configuration),
      t("work_reading.reach") => conversation_reach.presence || t("work_reading.unavailable"),
      t("work_reading.fallbacks") => captured_fallback_label(fallback_models),
    }
  end

  def attention_elapsed(task, as_of:, maintenance_now:)
    if task.status == "awaiting_input" || task.held?
      if task.await_started_at
        seconds = [task.run.effective_now(as_of, maintenance_now: maintenance_now) - task.await_started_at, 0].max
        t("work_reading.effective_wait", duration: distance_of_time_in_words(0, seconds))
      else
        t("work_reading.wait_unavailable")
      end
    elsif task.completed_at
      t("work_reading.failed_ago", duration: distance_of_time_in_words(task.completed_at, as_of))
    else
      t("work_reading.failure_time_unavailable")
    end
  end

  private

    # Deeply nested external text may exceed the parser or sanitizer's
    # supported depth. Keep the retained content readable as escaped text.
    def work_plain_text(source)
      tag.pre(tag.code(work_original_text(source)), class: "whitespace-pre-wrap wrap-anywhere")
    end

    def captured_tools_label(configuration)
      definitions = configuration&.tool_definitions
      definitions.nil? ? t("work_reading.unavailable") : t("work_reading.tool_count", count: definitions.length)
    end

    def captured_memory_label(configuration)
      return t("work_reading.unavailable") unless configuration

      configuration.memory_context_limit.nil? ? t("work_reading.no_extra_limit") : JSON.generate(configuration.memory_context_limit)
    end

    def captured_fallback_label(models)
      return t("work_reading.unavailable") if models.nil?

      models.present? ? models.join(" → ") : t("work_reading.no_fallbacks")
    end
end
