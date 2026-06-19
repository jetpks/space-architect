# frozen_string_literal: true

require "async"
require "pastel"

module SpaceCadet
  class Terminal
    SPINNER_FRAMES = %w[⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏].freeze

    attr_reader :stdout, :stderr, :config

    def initialize(config:, stdout: $stdout, stderr: $stderr, color_mode: "auto")
      @config = config
      @stdout = stdout
      @stderr = stderr
      @color_mode = color_mode.to_s.downcase
      color_mode
    end

    def interactive?
      stderr.tty?
    end

    def pastel
      @pastel ||= Pastel.new(enabled: colors_enabled?)
    end

    def say(message = "")
      stdout.puts(message)
    end

    def error(message)
      stderr.puts(colors_enabled? ? pastel.red(message) : message)
    end

    def success(message)
      say pastel.green(message)
    end

    def table(headers, rows)
      column_widths = headers.each_index.map do |index|
        ([headers[index]] + rows.map { |row| row[index].to_s }).map(&:length).max
      end

      ([headers] + rows).each_with_index.map do |row, row_index|
        table_row(headers, row, column_widths, header: row_index.zero?)
      end.join("\n")
    end

    def path(path)
      value = path.to_s
      homes.each do |home|
        return "~" if value == home
        return "~#{value.delete_prefix(home)}" if value.start_with?("#{home}/")
      end

      value
    end

    def with_spinner(message)
      return yield unless interactive?

      Warnings.without_experimental do
        Async do |task|
          spinner_task = start_spinner(task, message)
          yield
        ensure
          spinner_task&.stop
          begin
            spinner_task&.wait
          rescue StandardError
            nil
          end
          clear_spinner
        end.wait
      end
    end

    private

    def color_mode
      return @color_mode if %w[auto always never].include?(@color_mode)

      raise Error, "Invalid color mode '#{@color_mode}'. Expected one of: auto, always, never"
    end

    def colors_enabled?
      case color_mode
      when "always"
        true
      when "never"
        false
      else
        stdout.tty?
      end
    end

    def homes
      home = XDG.home(env: config.env)
      [home, realpath_or_nil(home)].compact.uniq
    end

    def realpath_or_nil(path)
      File.realpath(path)
    rescue SystemCallError
      nil
    end

    def table_row(headers, row, column_widths, header: false)
      row.each_with_index.map do |cell, index|
        raw = cell.to_s
        styled = header ? pastel.bold(raw) : style_table_cell(headers[index], raw)
        "#{styled}#{' ' * (column_widths[index] - raw.length)}"
      end.join("   ").rstrip
    end

    def style_table_cell(header, value)
      case header
      when "Status"
        style_status(value)
      when "Date"
        pastel.dim(value)
      when "Path"
        pastel.cyan(value)
      else
        value
      end
    end

    def style_status(status)
      case status
      when "active"
        pastel.green(status)
      when "paused"
        pastel.yellow(status)
      when "done"
        pastel.blue(status)
      when "archived"
        pastel.bright_black(status)
      else
        status
      end
    end

    def start_spinner(task, message)
      task.async do |spinner|
        frame_index = 0

        loop do
          text = message.respond_to?(:call) ? message.call : message.to_s
          frame = SPINNER_FRAMES[frame_index % SPINNER_FRAMES.length]
          stderr.print "\r\e[2K#{pastel.cyan(frame)} #{text}"
          stderr.flush
          frame_index += 1
          spinner.sleep(0.1)
        end
      end
    end

    def clear_spinner
      stderr.print "\r\e[2K"
      stderr.flush
    end
  end
end
