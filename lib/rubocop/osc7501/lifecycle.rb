# frozen_string_literal: true
# rbs_inline: enabled

require_relative 'writer'

module RuboCop
  # @rbs!
  #   class CLI
  #     attr_reader options: untyped
  #     def execute_runners: (*untyped args) ?{ (*untyped) -> untyped } -> untyped
  #   end
  #   class Runner
  #     def run: (*untyped args) ?{ (*untyped) -> untyped } -> untyped
  #     def aborting?: () -> bool
  #     private
  #     def formatter_set: () -> untyped
  #   end
  #   module Formatter
  #     class BaseFormatter
  #       attr_reader output: untyped
  #       attr_reader options: untyped
  #       def initialize: (untyped output, ?untyped options) -> void
  #       def started: (untyped target_files) -> void
  #       def file_finished: (untyped file, untyped offenses) -> void
  #       def finished: (untyped inspected_files) -> void
  #     end
  #   end

  module OSC7501
    # Private invocation hooks and observations for supported finite direct
    # RuboCop inspections. Require-time installation stays inert.
    module Lifecycle # :nodoc: all
      # Options that select a non-inspection command. These come from the
      # native parsed options at each supported boundary version.
      NON_INSPECTION_OPTIONS = %i[
        help version verbose_version show_cops list_enabled_cops_for
        show_docs_url explain lsp mcp init list_target_files auto_gen_config
      ].freeze

      FORMATTER_NAMES = ['RuboCop::OSC7501::Formatter', '::RuboCop::OSC7501::Formatter'].freeze
      THREAD_KEY = :rubocop_osc7501_invocation

      # Owns one invocation's counters, elected reporter and final outcome.
      class Invocation
        # @rbs @mode: String
        # @rbs @clock: Proc
        # @rbs @formatters: Array[[untyped, Writer]]
        # @rbs @reporter: untyped?
        # @rbs @reporter_writer: Writer?
        # @rbs @total: Integer?
        # @rbs @results: Integer
        # @rbs @offenses: Integer
        # @rbs @started: bool
        # @rbs @finished: bool
        # @rbs @closed: bool
        # @rbs @last_update: Float
        # @rbs @runner_aborting: bool
        # @rbs @current_file: String?

        attr_reader :mode, :reporter

        #: (mode: String, ?clock: Proc?) -> void
        def initialize(mode:, clock: nil)
          unless %w[auto off force].include?(mode)
            raise ArgumentError, 'RUBOCOP_OSC7501 must be auto, off, or force'
          end

          @mode = mode
          @clock = clock || proc { Process.clock_gettime(Process::CLOCK_MONOTONIC) }
          @formatters = []
          @reporter = nil
          @reporter_writer = nil
          @total = nil
          @results = 0
          @offenses = 0
          @started = false
          @finished = false
          @closed = false
          @last_update = @clock.call
          @runner_aborting = false
          @current_file = nil
        end

        # Registers a selected OSC formatter in native construction order.
        # The first formatter whose writer is enabled owns reporting.
        #: (untyped formatter, Writer writer) -> void
        def add_formatter(formatter, writer)
          @formatters << [formatter, writer]
          return unless @reporter.nil? && writer.enabled?

          @reporter = formatter
          @reporter_writer = writer
        end

        # Emits the initial working record after the native formatter set is
        # available, before target discovery and old warm-cache work.
        #: () -> nil
        def attach
          emit_working('Inspecting files')
          nil
        end

        #: (untyped formatter, Integer total) -> nil
        def started(formatter, total)
          return nil unless reporter.equal?(formatter)

          @started = true
          @total = total
          emit_working(count_message)
          nil
        end

        #: (untyped formatter, untyped file) -> nil
        def file_started(formatter, file)
          return nil unless reporter.equal?(formatter)

          @current_file = file.to_s
          now = @clock.call
          return nil if now - @last_update < 0.1

          @last_update = now
          emit_working(count_message, @current_file)
          nil
        end

        #: (untyped formatter, untyped offenses) -> nil
        def file_finished(formatter, offenses)
          return nil unless reporter.equal?(formatter)

          @results += 1
          @offenses += offenses.length if offenses.respond_to?(:length)
          now = @clock.call
          return nil if now - @last_update < 0.1

          @last_update = now
          emit_working(count_message, @current_file)
          nil
        end

        #: (untyped runner) -> nil
        def capture_runner(runner)
          @runner_aborting = runner.respond_to?(:aborting?) && runner.aborting?
          nil
        end

        #: (untyped status) -> nil
        def finish_result(status)
          if @runner_aborting
            finish('idle', 'Stopped')
          elsif status == 0
            finish('done', 'Inspection complete')
          else
            finish('error', 'Inspection failed')
          end
        end

        #: (Exception exception) -> nil
        def finish_exception(exception)
          stopped = exception.is_a?(Interrupt) || (exception.is_a?(SystemExit) && exception.success?)
          finish(stopped ? 'idle' : 'error', stopped ? 'Stopped' : 'Inspection failed')
        end

        # Closes still-open File outputs from a native formatter set that was
        # returned successfully before a later failure escaped the runner.
        #: (untyped formatter_set) -> nil
        def cleanup_native(formatter_set)
          formatter_set.each do |formatter|
            begin
              output = formatter.output
              output.close if output.is_a?(File) && !output.closed?
            rescue IOError, SystemCallError
              nil
            end
          end
          nil
        end

        # Releases every adapter-owned duplicate exactly once.
        #: () -> nil
        def close
          return nil if @closed

          @closed = true
          @formatters.each { |(_formatter, writer)| writer.close }
          nil
        end

        private

        #: (String, ?String?) -> void
        def emit_working(message, window_title = nil)
          return if @finished || reporter.nil?

          writer = @reporter_writer
          writer.emit(state: 'working', msg: message, window_title: window_title) if writer
        end

        #: (String, String) -> nil
        def finish(state, message)
          return nil if @finished

          @finished = true
          writer = @reporter_writer
          writer.emit(state: state, msg: outcome_message(message)) if writer
          nil
        end

        #: (String) -> String
        def outcome_message(message)
          return message unless @started

          "#{message}: #{count_message}"
        end

        #: () -> String
        def count_message
          "#{@results}/#{@total} file results, #{@offenses} reported offenses"
        end
      end

      # Prepended to RuboCop::CLI: owns context and finalization around the
      # private command boundary reached after --require has loaded the gem.
      # @rbs module-self RuboCop::CLI
      module CLIHook
        #: [T] (*untyped args) { (*untyped) -> T } -> T
        def execute_runners(*args, &block)
          invocation = Lifecycle.invocation_for(self)
          return super unless invocation

          previous = Lifecycle.current
          Lifecycle.current = invocation
          begin
            result = super
            invocation.finish_result(result)
            result
          rescue Exception => e # Record Interrupt and SystemExit before reraising.
            invocation.finish_exception(e)
            raise
          ensure
            invocation.close
            Lifecycle.current = previous
          end
        end
        private :execute_runners
      end

      # Prepended to RuboCop::Runner: participates only in an active selected
      # invocation, constructs the configured native formatter set early and
      # records the runner's existing abort state.
      # @rbs module-self RuboCop::Runner
      module RunnerHook
        #: [T] (*untyped args) { (*untyped) -> T } -> T
        def run(*args, &block)
          invocation = Lifecycle.current
          return super unless invocation

          native_set = nil
          begin
            native_set = formatter_set
            invocation.attach
            super
          ensure
            invocation.cleanup_native(native_set) if native_set
            invocation.capture_runner(self)
          end
        end
      end

      class << self
        # @rbs @installed: bool

        #: () -> void
        def install!
          return if @installed

          @installed = true
          RuboCop::CLI.prepend(CLIHook) if defined?(RuboCop::CLI)
          RuboCop::Runner.prepend(RunnerHook) if defined?(RuboCop::Runner)
          nil
        end

        #: () -> Invocation?
        def current
          Thread.current[THREAD_KEY]
        end

        #: (Invocation?) -> Invocation?
        def current=(invocation)
          Thread.current[THREAD_KEY] = invocation
        end

        #: (untyped cli) -> Invocation?
        def invocation_for(cli)
          options = cli.options
          return nil unless options
          return nil if NON_INSPECTION_OPTIONS.any? { |key| options.key?(key) }
          return nil unless selected?(options[:formatters])

          mode = ENV.fetch('RUBOCOP_OSC7501', 'auto')
          return nil if mode == 'off'

          Invocation.new(mode: mode)
        end

        #: (untyped formatters) -> bool
        def selected?(formatters)
          return false unless formatters.respond_to?(:any?)

          formatters.any? do |pair|
            type = pair.respond_to?(:first) ? pair.first : pair
            type.equal?(Formatter) || (type.is_a?(String) && FORMATTER_NAMES.include?(type))
          end
        end
      end
    end
  end
end
