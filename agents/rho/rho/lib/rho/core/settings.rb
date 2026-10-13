module Rho
  class Core
    module Settings
      def settings
        daemon = running_daemon
        unless daemon
          current = Config.load(@home.settings_path, home: @home)
          return { "settings" => current.to_h.slice(*Rho::Settings::PUBLIC_KEYS) }
        end
        response = get(daemon, "/settings")
        document = parse(response)
        refuse(response, document, "the daemon refused to read settings") unless response.code == "200"
        document
      end

      def settings_status
        response = get(require_daemon, "/settings/status", budget: Budget::KERNEL_ROUND_TRIP)
        document = parse(response)
        refuse(response, document, "the daemon refused to read setup status") unless response.code == "200"
        document
      end

      def update_settings(changes)
        daemon = running_daemon
        unless daemon
          return with_settings_writer do |writer|
            saved = writer.update(changes)
            { "settings" => saved.to_h.slice(*Rho::Settings::PUBLIC_KEYS) }
          end
        end

        response = patch(daemon, "/settings", changes, budget: Budget::KERNEL_ROUND_TRIP)
        document = parse(response)
        refuse(response, document, "the daemon refused to update settings") unless response.code == "200"
        document
      end

      def extensions
        daemon = running_daemon
        unless daemon
          current = Config.load(@home.settings_path, home: @home)
          loaded = Rho::Extensions.assemble([])
          return JSON.parse(JSON.generate(Rho::Extensions::Manager.document(home: @home, config: current, loaded: loaded)))
        end
        response = get(daemon, "/extensions")
        document = parse(response)
        refuse(response, document, "the daemon refused to list plugins") unless response.code == "200"
        document
      end

      def configure_extension(id, operations:, enabled: nil)
        id = Rho::Packages.package_name(id)
        daemon = running_daemon
        unless daemon
          return with_settings_writer do |writer|
            writer.update_plugin(id, operations: operations, enabled: enabled)
            { "saved" => true, "applied" => false, "restart_required" => false,
              "plugin" => extensions.fetch("plugins").find { |row| row.fetch("id") == id } }
          end
        end
        body = { operations: operations }
        body[:enabled] = enabled unless enabled.nil?
        response = patch(daemon, "/extensions/#{id}/configuration", body, budget: Budget::KERNEL_ROUND_TRIP)
        document = parse(response)
        refuse(response, document, "the daemon refused to configure the plugin") unless response.code == "200"
        document
      end

      def enable_extension(id, dependents: []) = change_extension(id, enabled: true, dependents: dependents)
      def disable_extension(id, dependents: []) = change_extension(id, enabled: false, dependents: dependents)

      def telegram_connections
        response = get(require_daemon, "/telegram/connections")
        document = parse(response)
        refuse(response, document, "the daemon refused to list Telegram Connections") unless response.code == "200"
        document
      end

      def telegram_connection(connection_public_id:)
        response = get(require_daemon, "/telegram/connection?#{URI.encode_www_form(connection_public_id: connection_public_id)}")
        document = parse(response)
        refuse(response, document, "the daemon refused to read the Telegram Connection") unless response.code == "200"
        document
      end

      def configure_telegram_connection(changes, connection_public_id: nil)
        body = changes.dup
        body["connection_public_id"] = connection_public_id if connection_public_id
        response = post(require_daemon, "/telegram/connection", body, budget: Budget::KERNEL_ROUND_TRIP)
        document = parse(response)
        refuse(response, document, "the daemon refused to configure the Telegram Connection") unless response.code == "200"
        document
      end

      def telegram_settings(agent_public_id:)
        response = get(require_daemon, "/telegram?#{URI.encode_www_form(agent_public_id: agent_public_id)}")
        document = parse(response)
        refuse(response, document, "the daemon refused to read Telegram settings") unless response.code == "200"
        document
      end

      def configure_telegram(changes, agent_public_id:)
        response = post(require_daemon, "/telegram/configuration", changes.merge("agent_public_id" => agent_public_id), budget: Budget::KERNEL_ROUND_TRIP)
        document = parse(response)
        refuse(response, document, "the daemon refused to configure Telegram") unless response.code == "200"
        document
      end

      def change_telegram_access(agent_public_id:, list:, action:, id:)
        response = post(require_daemon, "/telegram/access", { agent_public_id: agent_public_id, list: list, action: action, id: id },
          budget: Budget::KERNEL_ROUND_TRIP)
        document = parse(response)
        refuse(response, document, "the daemon refused to update Telegram access") unless response.code == "200"
        document
      end

      private

        def change_extension(id, enabled:, dependents:)
          id = Rho::Packages.package_name(id)
          daemon = running_daemon
          unless daemon
            return with_settings_writer do |writer|
              writer.update_plugin(id, operations: [], enabled: enabled, dependents: dependents)
              { "saved" => true, "applied" => false, "restart_required" => false }
            end
          end
          action = enabled ? "enable" : "disable"
          response = post(daemon, "/extensions/#{id}/#{action}", { dependents: dependents }, budget: Budget::KERNEL_ROUND_TRIP)
          document = parse(response)
          refuse(response, document, "the daemon refused to #{action} the plugin") unless response.code == "200"
          document
        end

        def with_settings_writer
          @home.prepare
          lock = Lock.acquire(@home.boot_lock_path)
          Rho::Settings.prepare(@home)
          current = Config::Current.new(Config.load(@home.settings_path, home: @home))
          writer = Rho::Settings.new(home: @home, config: current, apply: ->(_previous, _changes) { })
          yield writer
        rescue Lock::AlreadyHeld
          raise Rho::Error, "rho is starting or stopping; retry through its control API once it is ready"
        ensure
          lock&.release
        end
    end
  end
end
