# frozen_string_literal: true
# rbs_inline: enabled

require 'spec_helper'
require 'tmpdir'

class LifecycleTtyOutput < StringIO
  #: () -> bool
  def tty?
    true
  end
end

class LifecycleTtyFile < File
  #: () -> bool
  def tty?
    true
  end
end

RSpec.describe RuboCop::OSC7501::Lifecycle do
  let(:output) { StringIO.new }

  around do |example|
    original = ENV['RUBOCOP_OSC7501']
    ENV['RUBOCOP_OSC7501'] = 'force'
    example.run
  ensure
    original.nil? ? ENV.delete('RUBOCOP_OSC7501') : ENV['RUBOCOP_OSC7501'] = original
  end

  #: (String) -> RuboCop::OSC7501::Lifecycle::Invocation
  def invocation(mode = 'force')
    described_class::Invocation.new(mode: mode)
  end

  #: (RuboCop::OSC7501::Lifecycle::Invocation) -> RuboCop::OSC7501::Writer
  def attach(invocation)
    writer = RuboCop::OSC7501::Writer.new(output, mode: invocation.mode)
    invocation.add_formatter(Object.new, writer)
    invocation.attach
    writer
  end

  #: () -> Array[String]
  def terminal_states
    frames(output.string).select { |record| %w[done error idle].include?(record['state']) }
                         .map { |record| record['state'] }
  end

  describe 'final outcomes' do
    it 'maps status zero to done with observed counts' do
      inv = invocation
      attach(inv)
      inv.started(inv.reporter, 3)
      inv.file_finished(inv.reporter, [Object.new, Object.new])
      inv.finish_result(0)
      expect(terminal_states).to eq(['done'])
      expect(frames(output.string).last['msg']).to include('Inspection complete', '1/3 file results',
                                                           '2 reported offenses')
    end

    it 'maps a nonzero status to error without claiming offenses' do
      inv = invocation
      attach(inv)
      inv.finish_result(1)
      expect(terminal_states).to eq(['error'])
      expect(frames(output.string).last['msg']).to eq('Inspection failed')
    end

    it 'maps captured runner aborting to idle' do
      inv = invocation
      attach(inv)
      inv.capture_runner(Struct.new(:aborting?).new(true))
      inv.finish_result(1)
      expect(terminal_states).to eq(['idle'])
      expect(frames(output.string).last['msg']).to eq('Stopped')
    end

    it 'maps an escaping Interrupt to idle' do
      inv = invocation
      attach(inv)
      inv.finish_exception(Interrupt.new)
      expect(terminal_states).to eq(['idle'])
    end

    it 'maps successful SystemExit to idle and unsuccessful SystemExit to error' do
      successful = invocation
      attach(successful)
      successful.finish_exception(SystemExit.new(0))
      expect(terminal_states).to eq(['idle'])

      other_output = StringIO.new
      other = invocation
      writer = RuboCop::OSC7501::Writer.new(other_output, mode: 'force')
      other.add_formatter(Object.new, writer)
      other.attach
      other.finish_exception(SystemExit.new(2))
      expect(frames(other_output.string).last['state']).to eq('error')
    end

    it 'maps other escaping exceptions to error' do
      inv = invocation
      attach(inv)
      inv.finish_exception(RuntimeError.new('boom'))
      expect(terminal_states).to eq(['error'])
    end

    it 'never treats finished as a terminal record and finalizes only once' do
      previous = described_class.current
      described_class.current = nil
      inv = invocation
      described_class.current = inv
      local = StringIO.new
      formatter = RuboCop::OSC7501::Formatter.new(local)
      inv.attach
      formatter.started(%w[a b])
      formatter.finished([])
      inv.finish_result(0)
      inv.finish_result(1)
      inv.finish_exception(RuntimeError.new('late'))
      records = frames(local.string)
      expect(records.select { |record| %w[done error idle].include?(record['state']) }
                   .map { |record| record['state'] }).to eq(['done'])
    ensure
      described_class.current = previous
    end

    it 'keeps the primary exception identity through the CLI hook' do
      error = RuntimeError.new('kaput')
      cli = hooked_cli { raise error }
      expect { cli.send(:execute_runners) }.to raise_error do |raised|
        expect(raised).to equal(error)
      end
      expect(frames(output.string).last['state']).to eq('error')
    end

    it 'restores the previous thread context after success and failure' do
      previous = invocation
      described_class.current = previous
      success = hooked_cli { :value }
      expect(success.send(:execute_runners)).to eq(:value)
      expect(described_class.current).to equal(previous)

      failure = hooked_cli { raise 'boom' }
      expect { failure.send(:execute_runners) }.to raise_error('boom')
      expect(described_class.current).to equal(previous)
    ensure
      described_class.current = nil
    end
  end

  describe 'repeated and nested CLI calls' do
    it 'isolates context, records and output for nested invocations' do
      inner_output = StringIO.new
      outer_output = StringIO.new
      inner = hooked_cli(inner_output) { 0 }
      outer = hooked_cli(outer_output) do
        expect(described_class.current).to be_a(described_class::Invocation)
        expect(inner.send(:execute_runners)).to eq(0)
        expect(described_class.current).to be_a(described_class::Invocation)
        0
      end
      expect(outer.send(:execute_runners)).to eq(0)
      expect(frames(inner_output.string).map { |record| record['state'] }).to eq(%w[working done])
      expect(frames(outer_output.string).map { |record| record['state'] }).to eq(%w[working done])
      expect(described_class.current).to be_nil
    end

    it 'installs hooks exactly once across repeated activation' do
      described_class.install!
      described_class.install!
      cli_hooks = RuboCop::CLI.ancestors.count { |ancestor| ancestor.to_s.end_with?('CLIHook') }
      runner_hooks = RuboCop::Runner.ancestors.count { |ancestor| ancestor.to_s.end_with?('RunnerHook') }
      expect(cli_hooks).to eq(1)
      expect(runner_hooks).to eq(1)
      expect(RuboCop::CLI.private_method_defined?(:execute_runners)).to eq(true)
    end
  end

  describe 'native runner participation' do
    it 'emits the first working frame before discovery and closes native File outputs on early failure' do
      Dir.mktmpdir('rubocop osc7501 native ') do |directory|
        events = []
        native_file = File.open(File.join(directory, 'native.out'), 'w')
        native = Struct.new(:output).new(native_file)
        inv = invocation
        previous = described_class.current
        described_class.current = inv
        runner = fake_runner(events) do
          [native, RuboCop::OSC7501::Formatter.new(output)]
        end
        runner.define_singleton_method(:run) do |*_args|
          events << :discovery
          raise 'discovery failed'
        end
        runner.singleton_class.prepend(described_class::RunnerHook)
        begin
          expect { runner.run([]) }.to raise_error('discovery failed')
        ensure
          described_class.current = previous
          inv.close
        end
        expect(events).to eq(%i[formatters discovery])
        expect(frames(output.string).first['state']).to eq('working')
        expect(native_file.closed?).to eq(true)
      end
    end

    it 'leaves borrowed native streams open when a successful set unwinds' do
      inv = invocation
      previous = described_class.current
      described_class.current = inv
      borrowed = StringIO.new
      native = Struct.new(:output).new(borrowed)
      runner = fake_runner([]) { [native, RuboCop::OSC7501::Formatter.new(output)] }
      runner.define_singleton_method(:run) do |*_args|
        raise 'discovery failed'
      end
      runner.singleton_class.prepend(described_class::RunnerHook)
      begin
        expect { runner.run([]) }.to raise_error('discovery failed')
      ensure
        described_class.current = previous
        inv.close
      end
      expect(borrowed).not_to be_closed
    end

    it 'captures the existing aborting state for finalization' do
      inv = invocation
      runner = Struct.new(:aborting?).new(true)
      inv.capture_runner(runner)
      inv.finish_result(1)
      expect(inv.instance_variable_get(:@runner_aborting)).to eq(true)
    end
  end

  describe 'CLI hook exception wiring' do
    [
      ['successful SystemExit', SystemExit.new(0), 'idle'],
      ['unsuccessful SystemExit', SystemExit.new(3), 'error'],
      ['Interrupt', Interrupt.new, 'idle']
    ].each do |label, error, expected|
      it "re-raises #{label} with one final record and restores resources" do
        previous = described_class.current
        described_class.current = nil
        Dir.mktmpdir('rubocop osc7501 hook exception ') do |directory|
          path = File.join(directory, 'status.out')
          target = File.open(path, 'w')
          cli = hooked_cli(target) { raise error }
          expect { cli.send(:execute_runners) }.to raise_error do |raised|
            expect(raised).to equal(error)
          end
          expect(described_class.current).to be_nil
          writer = cli.formatter.instance_variable_get(:@writer)
          expect(writer.instance_variable_get(:@owned)).to be_nil
          expect(target).not_to be_closed
          records = frames(File.read(path))
          expect(records.select { |record| %w[done error idle].include?(record['state']) }
                       .map { |record| record['state'] }).to eq([expected])
          target.close
        end
      ensure
        described_class.current = previous
      end
    end
  end

  describe 'formatter construction ownership' do
    it 'allocates no duplicate without an active invocation' do
      Dir.mktmpdir('rubocop osc7501 inactive ') do |directory|
        file = File.open(File.join(directory, 'inactive.out'), 'w')
        expect(file).not_to receive(:dup)
        formatter = RuboCop::OSC7501::Formatter.new(file)
        expect(formatter.output).to equal(file)
        expect(file).not_to be_closed
        file.close
      end
    end

    it 'allocates no duplicate for later eligible selections and closes the elected duplicate' do
      inv = invocation
      previous = described_class.current
      described_class.current = inv
      Dir.mktmpdir('rubocop osc7501 later ') do |directory|
        first_file = File.open(File.join(directory, 'first.out'), 'w')
        second_file = File.open(File.join(directory, 'second.out'), 'w')
        expect(second_file).not_to receive(:dup)
        first = RuboCop::OSC7501::Formatter.new(first_file)
        second = RuboCop::OSC7501::Formatter.new(second_file)
        expect(inv.reporter).to equal(first)
        expect(second.instance_variable_get(:@writer)).to be_nil
        writer = first.instance_variable_get(:@writer)
        owned = writer.instance_variable_get(:@owned)
        inv.close
        expect(owned).to be_closed
        expect(first_file).not_to be_closed
        expect(second_file).not_to be_closed
        first_file.close
        second_file.close
      end
    ensure
      described_class.current = previous
    end

    it 'elects a later enabled formatter after a disabled auto selection' do
      original_term = ENV['TERM']
      ENV['TERM'] = 'xterm-256color'
      inv = invocation('auto')
      previous = described_class.current
      described_class.current = inv
      Dir.mktmpdir('rubocop osc7501 election ') do |directory|
        disabled = StringIO.new
        enabled_file = LifecycleTtyFile.open(File.join(directory, 'enabled.out'), 'w')
        expect(enabled_file).to receive(:dup).once.and_call_original
        RuboCop::OSC7501::Formatter.new(disabled)
        expect(inv.reporter).to be_nil
        second = RuboCop::OSC7501::Formatter.new(enabled_file)
        expect(inv.reporter).to equal(second)
        writer = second.instance_variable_get(:@writer)
        owned = writer.instance_variable_get(:@owned)
        inv.close
        expect(owned).to be_closed
        expect(enabled_file).not_to be_closed
        enabled_file.close
      end
    ensure
      described_class.current = previous
      original_term.nil? ? ENV.delete('TERM') : ENV['TERM'] = original_term
    end

    it 'never lets a custom subclass win over the documented formatter' do
      inv = invocation
      previous = described_class.current
      described_class.current = inv
      Dir.mktmpdir('rubocop osc7501 subclass ') do |directory|
        subclass_file = File.open(File.join(directory, 'subclass.out'), 'w')
        base_file = File.open(File.join(directory, 'base.out'), 'w')
        expect(subclass_file).not_to receive(:dup)
        subclass = Class.new(RuboCop::OSC7501::Formatter)
        custom = subclass.new(subclass_file)
        base = RuboCop::OSC7501::Formatter.new(base_file)
        expect(inv.reporter).to equal(base)
        expect(custom.instance_variable_get(:@writer)).to be_nil
        writer = base.instance_variable_get(:@writer)
        owned = writer.instance_variable_get(:@owned)
        inv.close
        expect(owned).to be_closed
        expect(subclass_file).not_to be_closed
        expect(base_file).not_to be_closed
        subclass_file.close
        base_file.close
      end
    ensure
      described_class.current = previous
    end
  end

  describe 'partial native construction' do
    it 'preserves the constructor failure and releases an owned duplicate without retrying' do
      Dir.mktmpdir('rubocop osc7501 partial ') do |directory|
        file = File.open(File.join(directory, 'native.out'), 'w')
        writer = RuboCop::OSC7501::Writer.new(file, mode: 'force')
        owned = writer.instance_variable_get(:@owned)
        inv = invocation
        previous = described_class.current
        described_class.current = inv
        calls = 0
        failure = RuntimeError.new('later formatter failed')
        runner = fake_runner([]) do
          calls += 1
          inv.add_formatter(Object.new, writer)
          raise failure
        end
        runner.singleton_class.prepend(described_class::RunnerHook)
        begin
          expect { runner.run([]) }.to raise_error do |raised|
            expect(raised).to equal(failure)
          end
        ensure
          described_class.current = previous
          inv.close
        end
        expect(calls).to eq(1)
        expect(owned).to be_closed
        expect(file).not_to be_closed
        file.close
      end
    end
  end

  describe 'formatter election' do
    it 'elects the first enabled reporter after a disabled auto selection' do
      original_term = ENV['TERM']
      ENV['TERM'] = 'xterm-256color'
      inv = invocation('auto')
      disabled = RuboCop::OSC7501::Writer.new(StringIO.new, mode: 'auto')
      enabled_output = LifecycleTtyOutput.new
      enabled = RuboCop::OSC7501::Writer.new(enabled_output, mode: 'auto')
      first = Object.new
      second = Object.new
      inv.add_formatter(first, disabled)
      inv.add_formatter(second, enabled)
      expect(disabled.enabled?).to eq(false)
      expect(inv.reporter).to equal(second)
      inv.attach
      inv.started(first, 2)
      inv.started(second, 2)
      inv.finish_result(0)
      expect(frames(enabled_output.string).map { |record| record['state'] }).to eq(%w[working working done])
      expect(frames(enabled_output.string).last['msg']).to include('0/2 file results')
    ensure
      original_term.nil? ? ENV.delete('TERM') : ENV['TERM'] = original_term
    end

    it 'ignores later selected formatters after election' do
      inv = invocation
      first_output = StringIO.new
      second_output = StringIO.new
      first = Object.new
      second = Object.new
      inv.add_formatter(first, RuboCop::OSC7501::Writer.new(first_output, mode: 'force'))
      inv.add_formatter(second, RuboCop::OSC7501::Writer.new(second_output, mode: 'force'))
      inv.attach
      inv.started(first, 3)
      inv.file_finished(first, [Object.new])
      inv.file_finished(second, [Object.new, Object.new])
      inv.finish_result(0)
      expect(frames(output.string)).to eq([])
      expect(frames(first_output.string).last['msg']).to include('1/3 file results', '1 reported offenses')
      expect(second_output.string).to eq('')
    end
  end

  describe 'selection and bypass' do
    it 'bypasses off, unselected and noninspection options without a context' do
      selected = { formatters: [['progress'], ['RuboCop::OSC7501::Formatter']] }
      ENV['RUBOCOP_OSC7501'] = 'off'
      expect(described_class.invocation_for(Struct.new(:options).new(selected))).to be_nil
      ENV['RUBOCOP_OSC7501'] = 'auto'
      expect(described_class.invocation_for(Struct.new(:options).new(selected))).to be_a(described_class::Invocation)

      unselected = { formatters: [['progress'], ['RuboCop::OSC7501::FormatterChild']] }
      expect(described_class.invocation_for(Struct.new(:options).new(unselected))).to be_nil
      described_class::NON_INSPECTION_OPTIONS.each do |key|
        expect(described_class.invocation_for(
                 Struct.new(:options).new(selected.merge(key => true))
               )).to be_nil, key.to_s
      end
    end

    it 'recognizes only the documented formatter class object or exact names' do
      expect(described_class.selected?([[RuboCop::OSC7501::Formatter]])).to eq(true)
      expect(described_class.selected?([['::RuboCop::OSC7501::Formatter']])).to eq(true)
      expect(described_class.selected?([[' RuboCop::OSC7501::Formatter']])).to eq(false)
      expect(described_class.selected?([[Class.new(RuboCop::OSC7501::Formatter)]])).to eq(false)
    end

    it 'rejects an invalid mode for a selected inspection' do
      ENV['RUBOCOP_OSC7501'] = 'loud'
      options = { formatters: [['RuboCop::OSC7501::Formatter']] }
      expect do
        described_class.invocation_for(Struct.new(:options).new(options))
      end.to raise_error(ArgumentError, /RUBOCOP_OSC7501/)
    end
  end

  describe 'window titles' do
    it 'titles the terminal with the current file and returns it to rubocop' do
      clock = { seconds: 0.0 }
      inv = described_class::Invocation.new(mode: 'force', clock: proc { clock[:seconds] })
      writer = RuboCop::OSC7501::Writer.new(output, mode: 'force')
      formatter = Object.new
      inv.add_formatter(formatter, writer)
      inv.attach
      inv.started(formatter, 2)
      clock[:seconds] = 0.2
      inv.file_started(formatter, 'app/models/user.rb')
      clock[:seconds] = 0.4
      inv.file_started(formatter, 'app/models/post.rb')
      inv.finish_result(0)
      expect(titles(output.string)).to eq(['rubocop',
                                           'rubocop',
                                           'rubocop › app/models/user.rb',
                                           'rubocop › app/models/post.rb',
                                           'rubocop'])
    end

    it 'keeps the last title while throttled file results update' do
      clock = { seconds: 0.0 }
      inv = described_class::Invocation.new(mode: 'force', clock: proc { clock[:seconds] })
      writer = RuboCop::OSC7501::Writer.new(output, mode: 'force')
      formatter = Object.new
      inv.add_formatter(formatter, writer)
      inv.attach
      inv.started(formatter, 2)
      clock[:seconds] = 0.2
      inv.file_started(formatter, 'lib/a.rb')
      inv.file_finished(formatter, [])
      inv.finish_result(0)
      expect(titles(output.string)).to eq(['rubocop',
                                           'rubocop',
                                           'rubocop › lib/a.rb',
                                           'rubocop'])
    end
  end

  describe 'throttling' do
    it 'bounds file-result updates to 0.1 monotonic seconds while initial and final bypass' do
      clock = { seconds: 0.0 }
      inv = described_class::Invocation.new(mode: 'force', clock: proc { clock[:seconds] })
      writer = RuboCop::OSC7501::Writer.new(output, mode: 'force')
      formatter = Object.new
      inv.add_formatter(formatter, writer)
      inv.attach
      inv.started(formatter, 4)
      clock[:seconds] = 0.05
      inv.file_finished(formatter, [Object.new])
      clock[:seconds] = 0.1
      inv.file_finished(formatter, [])
      clock[:seconds] = 0.15
      inv.file_finished(formatter, [])
      clock[:seconds] = 0.2
      inv.file_finished(formatter, [Object.new])
      inv.finish_result(0)
      messages = frames(output.string).map { |record| record['msg'] }
      expect(messages).to eq([
                               'Inspecting files',
                               '0/4 file results, 0 reported offenses',
                               '2/4 file results, 1 reported offenses',
                               '4/4 file results, 2 reported offenses',
                               'Inspection complete: 4/4 file results, 2 reported offenses'
                             ])
      expect(frames(output.string)).to all(satisfy { |record| !record.key?('progress') })
    end
  end

  #: (Array[Symbol]) { () -> Array[untyped] } -> untyped
  def fake_runner(events, &factory)
    klass = Class.new do
      attr_reader :aborting

      #: (Array[Symbol], untyped) -> void
      def initialize(seen, factory)
        @seen = seen
        @factory = factory
        @aborting = false
      end

      #: (*untyped) -> untyped
      def run(*args)
        @seen << :discovery
        args
      end

      #: () -> bool
      def aborting?
        @aborting
      end

      private

      #: () -> Array[untyped]
      def formatter_set
        @seen << :formatters
        @formatter_set ||= @factory.call
      end
    end
    klass.new(events, factory)
  end

  #: (?StringIO target) ?{ () -> untyped } -> untyped
  def hooked_cli(target = output, &body)
    klass = Class.new do
      attr_reader :options, :formatter

      #: (?untyped) -> void
      def initialize(body)
        @body = body
        @options = { formatters: [['progress'], ['RuboCop::OSC7501::Formatter']] }
      end

      #: (*untyped) -> untyped
      def execute_runners(*args)
        @formatter = RuboCop::OSC7501::Formatter.new(output)
        RuboCop::OSC7501::Lifecycle.current.attach
        @body ? @body.call(*args) : @formatter
      end

      private :execute_runners

      #: () -> StringIO
      def output
        @output ||= StringIO.new
      end
    end
    klass.prepend(described_class::CLIHook)
    instance = klass.new(body)
    instance.instance_variable_set(:@output, target)
    instance
  end
end
