# frozen_string_literal: true

require "json"

module Space
  module Server
    module Runs
      # Consumes normalized events and incrementally persists messages to a
      # conversation linked to the run.  Blocks are accumulated in memory;
      # a DB write happens on each message_complete (or tool_result).
      #
      # Usage:
      #   persistor = Persistor.new(conversations_repo, messages_repo)
      #   persistor.setup(run)        # creates the conversation, returns it
      #   events.each { persistor.process(_1) }
      #   run_record.conversation_id  # use persistor.conversation_id to link
      class Persistor
        attr_reader :conversation_id

        def initialize(conversations_repo, messages_repo)
          @conversations_repo = conversations_repo
          @messages_repo      = messages_repo
          reset!
        end

        # Creates a conversation owned by the run's user and returns it.
        # Must be called before process.
        def setup(run)
          conv = @conversations_repo.create(
            user_id:    run.user_id,
            status:     0,
            published:  false,
            source:     "architect_dispatch",
            created_at: Time.now,
            updated_at: Time.now
          )
          @conversation_id = conv.id
          conv
        end

        def process(event)
          case event[:type]
          when :message_start    then start_message(event)
          when :block_open       then open_block(event)
          when :text_delta       then append_text(event)
          when :tool_args_delta  then append_tool_args(event)
          when :block_close      then close_block(event)
          when :message_complete then flush_message
          when :tool_result      then write_tool_result(event)
          end
        end

        private

        def reset!
          @conversation_id = nil
          @position        = 0
          @current_msg     = nil
        end

        def start_message(event)
          @current_msg = { role: event[:role] || "assistant", model: event[:model], blocks: {}, ordered: [] }
        end

        def open_block(event)
          return unless @current_msg
          block = case event[:block_type]
                  when :text
                    { "type" => "text", "text" => "" }
                  when :thinking
                    { "type" => "thinking", "thinking" => "" }
                  when :tool_use
                    { "type" => "tool_use", "name" => event[:name], "id" => event[:tool_use_id], "input" => "" }
                  else
                    { "type" => event[:block_type].to_s }
                  end
          @current_msg[:blocks][event[:block_id]] = block
          @current_msg[:ordered] << block
        end

        def append_text(event)
          block = @current_msg&.dig(:blocks, event[:block_id])
          return unless block
          case block["type"]
          when "text"     then block["text"]     = block["text"].to_s     + event[:text].to_s
          when "thinking" then block["thinking"] = block["thinking"].to_s + event[:text].to_s
          end
        end

        def append_tool_args(event)
          block = @current_msg&.dig(:blocks, event[:block_id])
          return unless block && block["type"] == "tool_use"
          block["input"] = block["input"].to_s + event[:partial_json].to_s
        end

        def close_block(event)
          block = @current_msg&.dig(:blocks, event[:block_id])
          return unless block && block["type"] == "tool_use"
          raw = block["input"].to_s
          block["input"] = raw.empty? ? {} : (JSON.parse(raw) rescue {})
        end

        def flush_message
          return unless @current_msg && @conversation_id
          @messages_repo.create(
            conversation_id: @conversation_id,
            role:            @current_msg[:role],
            model:           @current_msg[:model],
            content:         @current_msg[:ordered],
            position:        @position,
            published:       false,
            created_at:      Time.now,
            updated_at:      Time.now
          )
          @position    += 1
          @current_msg  = nil
        end

        def write_tool_result(event)
          return unless @conversation_id
          # In real streams, tool_result fires before message_complete for the same turn.
          # Flush the pending assistant message first so positions are ordered correctly.
          flush_message
          @messages_repo.create(
            conversation_id: @conversation_id,
            role:            "user",
            content:         [{ "type" => "tool_result", "tool_use_id" => event[:tool_use_id],
                                "content" => event[:content], "is_error" => event[:is_error] }],
            position:        @position,
            published:       false,
            created_at:      Time.now,
            updated_at:      Time.now
          )
          @position += 1
        end
      end
    end
  end
end
