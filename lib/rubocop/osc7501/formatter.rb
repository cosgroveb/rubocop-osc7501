# frozen_string_literal: true
# rbs_inline: enabled

require 'rubocop/formatter/base_formatter'
require_relative 'lifecycle'
require_relative 'writer'

module RuboCop
  module OSC7501
    # Native RuboCop formatter selected alongside ordinary output. It only
    # observes callbacks; the private lifecycle owns election and outcomes.
    class Formatter < RuboCop::Formatter::BaseFormatter
      # @rbs @invocation: Lifecycle::Invocation?
      # @rbs @writer: Writer?

      #: (untyped output, ?untyped options) -> void
      def initialize(output, options = {})
        super
        @invocation = Lifecycle.current
        @writer = nil
        invocation = @invocation
        return unless invocation
        # v1 selection is the documented Formatter class only, so subclasses cannot win election.
        return unless self.class.equal?(Formatter)
        return if invocation.reporter

        writer = Writer.new(output, mode: invocation.mode)
        @writer = writer
        invocation.add_formatter(self, writer)
      end

      #: (untyped files) -> nil
      def started(files)
        invocation = @invocation
        invocation.started(self, files.length) if invocation
        nil
      end

      #: (untyped file, untyped offenses) -> nil
      def file_finished(_file, offenses)
        invocation = @invocation
        invocation.file_finished(self, offenses) if invocation
        nil
      end
    end
  end
end
