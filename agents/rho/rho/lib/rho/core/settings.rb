module Rho
  class Core
    module Settings
      def settings
        response = get(require_daemon, "/settings")
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
          changes = changes.to_h.transform_keys(&:to_s)
          current = Config.load(@home.settings_path)
          candidate = current.with(changes)
          settings = Config.read(@home.settings_path).merge(candidate.to_h.slice(*changes.keys))
          @home.write_settings(settings)
          return { "settings" => settings.slice(*Rho::Settings::PUBLIC_KEYS) }
        end

        response = patch(daemon, "/settings", changes, budget: Budget::KERNEL_ROUND_TRIP)
        document = parse(response)
        refuse(response, document, "the daemon refused to update settings") unless response.code == "200"
        document
      end

      def telegram_settings
        response = get(require_daemon, "/telegram")
        document = parse(response)
        refuse(response, document, "the daemon refused to read Telegram settings") unless response.code == "200"
        document
      end

      def configure_telegram(changes)
        response = post(require_daemon, "/telegram/configuration", changes, budget: Budget::KERNEL_ROUND_TRIP)
        document = parse(response)
        refuse(response, document, "the daemon refused to configure Telegram") unless response.code == "200"
        document
      end

      def change_telegram_access(list:, action:, id:)
        response = post(require_daemon, "/telegram/access", { list: list, action: action, id: id },
          budget: Budget::KERNEL_ROUND_TRIP)
        document = parse(response)
        refuse(response, document, "the daemon refused to update Telegram access") unless response.code == "200"
        document
      end
    end
  end
end
