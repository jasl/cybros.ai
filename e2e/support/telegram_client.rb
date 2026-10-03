module E2E
  # Only Telegram is replaced. Nexus, Core, the Bridge and Runtime stay real.
  class TelegramClient
    BOT = { "id" => 42, "username" => "rho_bot", "can_read_all_group_messages" => true }.freeze

    attr_reader :calls, :uploads, :downloads, :messages
    attr_accessor :refuse_next_formal

    def initialize
      @calls = []
      @uploads = []
      @downloads = []
      @files = {}
      @members = {}
      @messages = {}
    end

    def call(method, params = {}, **)
      return BOT if method == "getMe"
      if method == "getChatMember"
        return @members.fetch([params.fetch(:chat_id).to_s, params.fetch(:user_id).to_s])
      end
      if method == "getFile"
        id = params.fetch(:file_id)
        return { "file_path" => id, "file_size" => @files.fetch(id).bytesize }
      end

      unless %w[sendMessage sendMessageDraft editMessageText answerCallbackQuery].include?(method)
        raise "Unexpected Telegram method: #{method}"
      end

      if @refuse_next_formal && method == "sendMessage" && params[:parse_mode] == "HTML"
        @refuse_next_formal = false
        raise Rho::IngressTelegram::Client::Refused.new(code: 429, description: "Retry later", retry_after: 1)
      end

      @calls << [method, params]
      message_id = @calls.length + @uploads.length
      @messages[message_id] = params.dup if method == "sendMessage"
      @messages.fetch(params.fetch(:message_id)).merge!(text: params.fetch(:text)) if method == "editMessageText"
      { "message_id" => message_id }
    end

    def close; end

    def provide_file(id, bytes)
      @files[id] = bytes
    end

    def provide_member(chat_id, user_id, status:)
      @members[[chat_id.to_s, user_id.to_s]] = { "status" => status }
    end

    def download(path, max_bytes:)
      bytes = @files.fetch(path)
      raise "Telegram download exceeds the caller's bound" if bytes.bytesize > max_bytes

      @downloads << path
      bytes
    end

    def upload(method, params, bytes:, filename:, content_type:, field:)
      unless %w[sendPhoto sendDocument sendVoice].include?(method)
        raise "Unexpected Telegram upload: #{method}"
      end

      @uploads << { method: method, params: params, bytes: bytes, filename: filename,
                    content_type: content_type, field: field }
      { "message_id" => @calls.length + @uploads.length }
    end

    def formal(chat_id)
      @calls.select do |method, params|
        method == "sendMessage" && params[:parse_mode] == "HTML" && params.fetch(:chat_id) == chat_id.to_s
      end
    end
  end

  class TelegramLostAckBridge < Rho::IngressTelegram::Bridge
    attr_accessor :lose_next_ack, :lose_next_stop_ack
    attr_accessor :lose_next_participation_ack, :lose_next_participation_record_ack
    attr_reader :stops, :participation_starts, :participation_records

    def participation_start(**fields)
      result = super
      (@participation_starts ||= []) << { fields: fields, result: result }
      if @lose_next_participation_ack
        @lose_next_participation_ack = false
        raise Rho::ConnectionError, "The accepted OneShot response was lost"
      end
      result
    end

    def record_participation(conversation_id, **fields)
      result = super
      (@participation_records ||= []) << { conversation_id: conversation_id, fields: fields, input_id: result }
      if @lose_next_participation_record_ack
        @lose_next_participation_record_ack = false
        raise Rho::ConnectionError, "The accepted assistant message response was lost"
      end
      result
    end

    def submit(...)
      result = super
      if @lose_next_ack
        @lose_next_ack = false
        raise Rho::ConnectionError, "The accepted response was lost"
      end
      result
    end

    def stop(id, **options)
      (@stops ||= []) << id
      result = super
      if @lose_next_stop_ack
        @lose_next_stop_ack = false
        raise Rho::ConnectionError, "The successful Stop response was lost"
      end
      result
    end
  end
end
