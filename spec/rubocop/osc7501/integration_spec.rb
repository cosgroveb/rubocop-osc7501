# frozen_string_literal: true
# rbs_inline: enabled

require 'json'
require 'spec_helper'
require_relative '../../support/process_helpers'

CLEAN = "# frozen_string_literal: true\n\nputs 'clean'\n"
OFFENSE = "def bad( x )\n  x+1\nend\n"
CONFIG = "AllCops:\n  NewCops: disable\n"

RSpec.describe 'RuboCop OSC7501 integration' do

  #: (String) -> String
  def normalize(text)
    text.gsub(%r{#{Regexp.escape(Dir.tmpdir)}/[^/\s]+/}, '<tmp>/')
  end

  #: (argv: Array[String], ?mode: String, ?files: Hash[String, String]) -> Hash[Symbol, untyped]
  def run(argv:, mode: 'force', files: {})
    ProcessHelpers.run(argv: argv, mode: mode, files: { '.rubocop.yml' => CONFIG }.merge(files))
  end

  #: (Hash[Symbol, untyped], Hash[Symbol, untyped]) -> void
  def expect_parity(enabled, disabled)
    expect(normalize(enabled[:stdout])).to eq(normalize(disabled[:stdout]))
    expect(normalize(enabled[:stderr])).to eq(normalize(disabled[:stderr]))
    expect(enabled[:status].exitstatus).to eq(disabled[:status].exitstatus)
    expect(enabled[:status].termsig).to eq(disabled[:status].termsig)
  end

  #: (Hash[Symbol, untyped]) -> Array[String]
  def terminal_states(result)
    result[:frames].select { |record| %w[done error idle].include?(record['state']) }
                   .map { |record| record['state'] }
  end

  it 'preserves clean inspection output and reports done' do
    argv = ['--require', 'rubocop/osc7501', '--format', 'progress',
            '--format', 'RuboCop::OSC7501::Formatter', 'clean.rb']
    enabled = run(argv: argv, files: { 'clean.rb' => CLEAN })
    disabled = run(argv: argv, mode: 'off', files: { 'clean.rb' => CLEAN })
    expect_parity(enabled, disabled)
    expect(enabled[:status].exitstatus).to eq(0)
    expect(terminal_states(enabled)).to eq(['done'])
    expect(enabled[:frames].first).to include('app' => 'rubocop', 'title' => 'RuboCop',
                                              'state' => 'working', 'msg' => 'Inspecting files')
  end

  it 'preserves offense output and reports error' do
    argv = ['--require', 'rubocop/osc7501', '--format', 'progress',
            '--format', 'RuboCop::OSC7501::Formatter', 'bad.rb']
    enabled = run(argv: argv, files: { 'bad.rb' => OFFENSE })
    disabled = run(argv: argv, mode: 'off', files: { 'bad.rb' => OFFENSE })
    expect_parity(enabled, disabled)
    expect(enabled[:status].exitstatus).to eq(1)
    expect(terminal_states(enabled)).to eq(['error'])
    expect(enabled[:frames].last['msg']).to include('Inspection failed', '1/1 file results')
    expect(enabled[:frames].last['msg']).not_to include('offenses found')
  end

  it 'respects fail-level without inferring success from offense counts' do
    argv = ['--require', 'rubocop/osc7501', '--format', 'progress',
            '--format', 'RuboCop::OSC7501::Formatter', '--fail-level', 'error', 'bad.rb']
    enabled = run(argv: argv, files: { 'bad.rb' => OFFENSE })
    disabled = run(argv: argv, mode: 'off', files: { 'bad.rb' => OFFENSE })
    expect_parity(enabled, disabled)
    expect(enabled[:status].exitstatus).to eq(0)
    expect(terminal_states(enabled)).to eq(['done'])
  end

  it 'preserves autocorrect streams and outcomes' do
    argv = ['--require', 'rubocop/osc7501', '--format', 'progress',
            '--format', 'RuboCop::OSC7501::Formatter', '--autocorrect', 'bad.rb']
    enabled = run(argv: argv, files: { 'bad.rb' => OFFENSE })
    disabled = run(argv: argv, mode: 'off', files: { 'bad.rb' => OFFENSE })
    expect_parity(enabled, disabled)
    expect(terminal_states(enabled)).to eq([enabled[:status].exitstatus.zero? ? 'done' : 'error'])
  end

  it 'contains internal cop failures and preserves their error outcome' do
    cop = <<~RUBY
      # frozen_string_literal: true
      module RuboCop
        module Cop
          class Exploding < Base
            def on_send(_node)
              raise 'cop failed'
            end
          end
        end
      end
    RUBY
    argv = ['--require', './exploding.rb', '--require', 'rubocop/osc7501',
            '--format', 'progress', '--format', 'RuboCop::OSC7501::Formatter', 'bad.rb']
    enabled = run(argv: argv, files: { 'bad.rb' => CLEAN, 'exploding.rb' => cop })
    disabled = run(argv: argv, mode: 'off', files: { 'bad.rb' => CLEAN, 'exploding.rb' => cop })
    expect_parity(enabled, disabled)
    expect(enabled[:status].exitstatus).not_to eq(0)
    expect(terminal_states(enabled)).to eq(['error'])
  end

  it 'closes a completed native formatter set when Runner catches an early Interrupt' do
    source = <<~RUBY
      require 'json'
      require 'rubocop/osc7501'

      outputs = []
      closed_owned = []
      formatter_set_calls = 0

      RuboCop::Formatter::BaseFormatter.prepend(Module.new do
        define_method(:initialize) do |output, options = {}|
          outputs << output
          super(output, options)
        end
      end)

      RuboCop::OSC7501::Writer.prepend(Module.new do
        define_method(:close) do
          owned = instance_variable_get(:@owned)
          result = super()
          closed_owned << (owned && owned.closed?)
          result
        end
      end)

      RuboCop::Runner.prepend(Module.new do
        define_method(:formatter_set) do
          formatter_set_calls += 1
          super()
        end
      end)

      RuboCop::TargetFinder.prepend(Module.new do
        define_method(:find) { |*_args| raise Interrupt }
      end)

      status = RuboCop::CLI.new.run(['--no-server', '--format', 'progress',
                                     '--format', 'RuboCop::OSC7501::Formatter',
                                     '--out', 'status.txt', 'clean.rb'])
      open_native_outputs = outputs.count { |output| output.is_a?(File) && !output.closed? }
      File.write('result.json', JSON.generate(status: status, open_native_outputs: open_native_outputs,
                                              closed_owned: closed_owned,
                                              formatter_set_calls: formatter_set_calls))
    RUBY
    result = ProcessHelpers.run_ruby(source, files: { '.rubocop.yml' => CONFIG, 'clean.rb' => CLEAN })
    payload = JSON.parse(result[:artifacts].fetch('result.json'))
    expect(payload['status']).to eq(130)
    expect(payload['open_native_outputs']).to eq(0)
    expect(payload['formatter_set_calls']).to eq(1)
    expect(payload['closed_owned']).not_to be_empty
    expect(payload['closed_owned']).to all(be(true))
    records = FrameHelpers.frames_from(result[:artifacts].fetch('status.txt'))
    expect(records.select { |record| %w[done error idle].include?(record['state']) }
                 .map { |record| record['state'] }).to eq(['idle'])
  end

  it 'preserves fail-fast behavior' do
    argv = ['--require', 'rubocop/osc7501', '--format', 'progress',
            '--format', 'RuboCop::OSC7501::Formatter', '--fail-fast', 'a.rb', 'b.rb']
    files = { 'a.rb' => OFFENSE, 'b.rb' => OFFENSE }
    enabled = run(argv: argv, files: files)
    disabled = run(argv: argv, mode: 'off', files: files)
    expect_parity(enabled, disabled)
    expect(enabled[:status].exitstatus).to eq(1)
    expect(terminal_states(enabled)).to eq(['error'])
  end

  it 'preserves a load failure before the supported command boundary' do
    argv = ['--require', 'rubocop/osc7501', '--require', './missing.rb',
            '--format', 'progress', '--format', 'RuboCop::OSC7501::Formatter', 'clean.rb']
    enabled = run(argv: argv, files: { 'clean.rb' => CLEAN })
    disabled = run(argv: argv, mode: 'off', files: { 'clean.rb' => CLEAN })
    expect_parity(enabled, disabled)
    expect(enabled[:status].exitstatus).not_to eq(0)
    expect(enabled[:frames]).to eq([])
  end

  it 'preserves configuration failure boundaries' do
    argv = ['--require', 'rubocop/osc7501', '--format', 'progress',
            '--format', 'RuboCop::OSC7501::Formatter', 'clean.rb']
    files = { '.rubocop.yml' => "AllCops: [\n", 'clean.rb' => CLEAN }
    enabled = ProcessHelpers.run(argv: argv, mode: 'force', files: files)
    disabled = ProcessHelpers.run(argv: argv, mode: 'off', files: files)
    expect_parity(enabled, disabled)
    expect(enabled[:status].exitstatus).not_to eq(0)
  end

  it 'bypasses noninspection modes without records' do
    [['--version'], ['--list-target-files', 'clean.rb']].each do |argv|
      result = run(argv: ['--require', 'rubocop/osc7501', *argv], files: { 'clean.rb' => CLEAN })
      expect(result[:frames]).to eq([]), argv.join(' ')
      expect(result[:status].exitstatus).to eq(0), argv.join(' ')
    end
  end

  it 'rejects an invalid global mode for a selected inspection' do
    argv = ['--require', 'rubocop/osc7501', '--format', 'progress',
            '--format', 'RuboCop::OSC7501::Formatter', 'clean.rb']
    result = run(argv: argv, mode: 'loud', files: { 'clean.rb' => CLEAN })
    expect(result[:status].exitstatus).to eq(2)
    expect(result[:stderr]).to include('RUBOCOP_OSC7501 must be auto, off, or force')
    expect(result[:frames]).to eq([])
  end

  it 'silences unselected, off, and non-TTY auto modes' do
    selected = ['--require', 'rubocop/osc7501', '--format', 'progress',
                '--format', 'RuboCop::OSC7501::Formatter', 'clean.rb']
    unselected = ['--require', 'rubocop/osc7501', '--format', 'progress', 'clean.rb']
    expect(run(argv: unselected, files: { 'clean.rb' => CLEAN })[:frames]).to eq([])
    expect(run(argv: selected, mode: 'off', files: { 'clean.rb' => CLEAN })[:frames]).to eq([])
    expect(run(argv: selected, mode: 'auto', files: { 'clean.rb' => CLEAN })[:frames]).to eq([])
  end

  it 'routes status to an owned duplicate of a File --out destination' do
    argv = ['--require', 'rubocop/osc7501', '--format', 'progress',
            '--format', 'RuboCop::OSC7501::Formatter', '--out', 'status.txt', 'clean.rb']
    result = run(argv: argv, files: { 'clean.rb' => CLEAN })
    expect(result[:status].exitstatus).to eq(0)
    expect(result[:frames]).to eq([])
    expect(terminal_states(result)).to eq([])
    contents = result[:artifacts].fetch('status.txt')
    expect(FrameHelpers.frames_from(contents).last['state']).to eq('done')
    expect(result[:stdout]).to include('1 file inspected')
  end

  it 'activates from the copied example argument file' do
    arguments = File.read(File.expand_path('../../../examples/.rubocop', __dir__))
    files = { '.rubocop' => arguments, '.rubocop.yml' => CONFIG, 'clean.rb' => CLEAN }
    enabled = ProcessHelpers.run(argv: ['clean.rb'], mode: 'force', files: files)
    disabled = ProcessHelpers.run(argv: ['clean.rb'], mode: 'off', files: files)
    expect_parity(enabled, disabled)
    expect(enabled[:status].exitstatus).to eq(0)
    expect(enabled[:frames].first).to include('state' => 'working', 'msg' => 'Inspecting files')
    expect(terminal_states(enabled)).to eq(['done'])
  end

  it 'preserves multiple formatter destinations' do
    argv = ['--require', 'rubocop/osc7501', '--format', 'progress', '--out', 'ordinary.txt',
            '--format', 'RuboCop::OSC7501::Formatter', '--out', 'status.txt', 'clean.rb']
    result = run(argv: argv, files: { 'clean.rb' => CLEAN })
    expect(result[:status].exitstatus).to eq(0)
    expect(result[:frames]).to eq([])
    expect(result[:artifacts].fetch('ordinary.txt')).to include('1 file inspected')
    expect(FrameHelpers.frames_from(result[:artifacts].fetch('status.txt')).last['state']).to eq('done')
  end

  it 'reports done for an empty target set' do
    argv = ['--require', 'rubocop/osc7501', '--format', 'progress',
            '--format', 'RuboCop::OSC7501::Formatter', '--force-exclusion', 'clean.rb']
    files = { '.rubocop.yml' => "#{CONFIG}  Exclude:\n    - '**/*'\n", 'clean.rb' => CLEAN }
    enabled = ProcessHelpers.run(argv: argv, mode: 'force', files: files)
    disabled = ProcessHelpers.run(argv: argv, mode: 'off', files: files)
    expect_parity(enabled, disabled)
    expect(enabled[:status].exitstatus).to eq(0)
    expect(terminal_states(enabled)).to eq(['done'])
  end

  it 'isolates repeated CLI invocations in one process' do
    source = <<~RUBY
      require 'rubocop/osc7501'
      statuses = 2.times.map do
        RuboCop::CLI.new.run(['--no-server', '--format', 'progress',
                              '--format', 'RuboCop::OSC7501::Formatter', 'clean.rb'])
      end
      exit statuses.max
    RUBY
    result = ProcessHelpers.run_ruby(source, files: { '.rubocop.yml' => CONFIG, 'clean.rb' => CLEAN })
    expect(result[:status].exitstatus).to eq(0)
    states = result[:frames].select { |record| %w[done error idle].include?(record['state']) }
                           .map { |record| record['state'] }
    expect(states).to eq(%w[done done])
    expect(result[:frames].count { |record| record['state'] == 'working' }).to be >= 4
  end
end
