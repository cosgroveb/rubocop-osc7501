# frozen_string_literal: true
# rbs_inline: enabled

module RuboCop
  module OSC7501
    # Encodes status records onto an output stream following the family
    # writer contract. Private to the adapter.
    class Writer # :nodoc: all
      # Base64 of "RuboCop".
      ENCODED_TITLE = ['RuboCop'].pack('m0').freeze

      # @rbs @output: IO | StringIO
      # @rbs @enabled: bool
      # @rbs @owned: IO?

      #: (IO | StringIO output, mode: String) -> void
      def initialize(output, mode:)
        @output = output
        @owned = nil
        @enabled = mode == 'force' || (mode == 'auto' && automatic_output?)
        own_output if @enabled
      rescue IOError, SystemCallError
        @enabled = false
      end

      #: () -> bool
      def enabled?
        @enabled
      end

      #: (state: String, msg: String) -> nil
      def emit(state:, msg:)
        return nil unless @enabled

        fields = ['app=rubocop', "title=#{ENCODED_TITLE}", "state=#{state}", "msg=#{encode(msg, 2048)}"]
        @output.write("\e]7501;#{fields.join(':')}\e\\")
        @output.flush if @output.respond_to?(:flush)
        nil
      rescue IOError, SystemCallError
        # Reporting failures disable reporting without disturbing the command.
        @enabled = false
        close
        nil
      end

      # Closes only a descriptor duplicated from an enabled File output.
      #: () -> nil
      def close
        output = @owned
        @owned = nil
        output.close if output && !output.closed?
        nil
      rescue IOError, SystemCallError
        nil
      end

      private

      #: () -> void
      def own_output
        return unless @output.is_a?(File)

        @owned = @output.dup #: IO
        @output = @owned
      rescue IOError, SystemCallError
        @enabled = false
        @owned = nil
      end

      #: () -> bool
      def automatic_output?
        ENV['TERM'] != 'dumb' && @output.respond_to?(:tty?) && @output.tty?
      end

      #: (String, Integer) -> String
      def encode(text, byte_limit)
        input = text.to_s.byteslice(0, sanitization_byte_limit(byte_limit)) #: String
        plain = input.encode('UTF-8', invalid: :replace, undef: :replace)
        plain = plain.gsub(/\e\[[0-9;?]*[ -\/]*[@-~]/, '')
        plain = plain.gsub(/[\u0000-\u001F\u007F-\u009F]/, ' ')
        clean = plain.gsub(/\s+/, ' ').strip
        bytes = 0
        bounded = clean.each_char.take_while do |char|
          bytes += char.bytesize
          bytes <= byte_limit
        end.join
        [bounded].pack('m0')
      end

      # Bound sanitization work with 50% headroom for removed formatting.
      #: (Integer) -> Integer
      def sanitization_byte_limit(output_byte_limit)
        output_byte_limit + output_byte_limit / 2
      end
    end
  end
end
