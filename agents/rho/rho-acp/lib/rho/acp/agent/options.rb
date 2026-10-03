module Rho
  module Acp
    class Agent
      # MODES AND CONFIG OPTIONS — ONE FIELD, TWO VIEWS: both documents are rendered from the session's two fields.
      # `modes {currentModeId, availableModes}` names the three postures
      # (`bypass`, `ask`, `rules` — UI text); `configOptions` carries the
      # same mode as a select and the MODEL as a second select whose
      # current value is the session's model else the home's
      # `default_model`. A client that supports config options ignores
      # `modes` (the spec). `set_mode` remembers the mode for the NEXT
      # prompt (the running turn's mode is frozen per input) and sends no
      # `current_mode_update` (that is for agent-initiated changes);
      # `set_config_option` `mode` is `set_mode`, `model` remembers a ref
      # sent on the next `say(model:)`.
      # THE MODEL PICKER'S OPTIONS: the refs this surface knows — the session's, the home's
      # default, the `--model` flag's, and every ref the picker learned. `Core#providers`
      # answers the lanes with a COUNT of models, never their refs
      # (`ModelProviderLane#models`), so a value outside the options is asked of the kernel
      # through `Core#model_facts` (`known`): a known ref is learned into the options and set,
      # an unknown one is -32602 with the kernel's word. The picker lets a person choose
      # explicitly; the kernel resolves the supplied reference and does not choose a model for
      # the application.
      module Options
        MODES = [
          { "id" => "bypass", "name" => "Bypass", "description" => "every call runs; rho's deny floor stands" },
          { "id" => "ask", "name" => "Ask", "description" => "hold every effect for your approval; reads run" },
          { "id" => "rules", "name" => "Rules", "description" => "refuse every call no rule allows; reads run" },
        ].freeze
        MODE_IDS = MODES.map { |mode| mode.fetch("id") }.freeze

        module_function

        # The two views together: `session/new`, `load`, `resume` answer them.
        def document(agent, session)
          { "modes" => modes(session), "configOptions" => config_options(agent, session) }
        end

        def modes(session)
          { "currentModeId" => session.mode, "availableModes" => MODES }
        end

        def config_options(agent, session)
          [
            {
              "id" => "mode", "name" => "Mode", "category" => "mode", "type" => "select",
              "currentValue" => session.mode,
              "options" => MODES.map { |mode| { "value" => mode.fetch("id"), "name" => mode.fetch("name"), "description" => mode.fetch("description") } },
            },
            {
              "id" => "model", "name" => "Model", "category" => "model", "type" => "select",
              "currentValue" => current_model(agent, session).to_s,
              "options" => model_refs(agent, session).map { |ref| { "value" => ref, "name" => ref } },
            },
          ]
        end

        def current_model(agent, session) = session.model || agent.default_model

        def model_refs(agent, session)
          [session.model, agent.model, agent.default_model, *session.models].compact.uniq
        end

        def set_mode(session, mode_id)
          raise Refusal.invalid_params("unknown mode #{mode_id.inspect}; one of #{MODE_IDS.join(", ")}") unless
            MODE_IDS.include?(mode_id)

          session.mode = mode_id
          nil
        end

        def set_config_option(agent, core, session, config_id, value)
          case config_id
          when "mode" then set_mode(session, value)
          when "model" then set_model(agent, core, session, value)
          else raise Refusal.invalid_params("unknown config option #{config_id.inspect}; one of mode, model")
          end
        end

        def set_model(agent, core, session, value)
          raise Refusal.invalid_params("model must be a provider/reference string") unless value.is_a?(String) && !value.empty?

          unless model_refs(agent, session).include?(value)
            facts = core.model_facts(value)
            raise Refusal.invalid_params("the kernel does not know the model #{value}") unless facts["known"] == true

            session.learn_model(value)
          end
          session.model = value
          nil
        end
      end
    end
  end
end
