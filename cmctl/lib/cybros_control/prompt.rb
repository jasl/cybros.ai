module CybrosControl
  # Both operator setup and rho's first-run flow use the same terminal input.
  class Prompt
    def initialize(input: $stdin, output: $stdout)
      @input, @output = input, output
    end

    def interactive? = @input.tty? && @output.tty?

    def say(text = "")
      @output.puts(text)
    end

    def ask(label, default: nil, secret: false)
      suffix = default.nil? || secret ? "" : " [#{default}]"
      @output.print("#{label}#{suffix}: ")
      @output.flush
      value = if secret
        @input.noecho(&:gets)
      else
        @input.gets
      end
      say if secret
      raise Cancelled, "Setup cancelled. Completed settings have been kept." if value.nil?

      value = secret ? value.chomp : value.strip
      value.empty? && !default.nil? ? default : value
    end

    def choose(label, choices:, default: 0)
      say(label)
      choices.each_with_index { |choice, index| say("  #{index + 1}. #{choice}") }
      loop do
        value = ask("Choose a number", default: (default + 1).to_s)
        if value.match?(/\A[1-9][0-9]*\z/) && value.to_i <= choices.length
          return value.to_i - 1
        end
        say("Enter a number from 1 to #{choices.length}.")
      end
    end

    def confirm(label, default: true)
      loop do
        value = ask("#{label} (y/n)", default: default ? "y" : "n").downcase
        case value
        when "y", "yes" then return true
        when "n", "no" then return false
        else say("Enter y or n.")
        end
      end
    end
  end
end
