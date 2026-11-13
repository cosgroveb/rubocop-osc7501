# frozen_string_literal: true
# rbs_inline: enabled

require 'fileutils'
require 'open3'
require 'rbconfig'
require 'rubocop'
require 'tmpdir'

# Runtime compatibility acceptance against the selected installed RuboCop.
# Written for Ruby 2.1 compatible syntax; no RSpec or modern tooling.
class Compat
  ROOT = File.expand_path('..', __dir__ || '.')
  LIB = File.join(ROOT, 'lib')
  CONFIG = "AllCops:\n  NewCops: disable\n"

  CLEAN = "# frozen_string_literal: true\n\nputs 'clean'\n"
  OFFENSE = "def bad( x )\n  x+1\nend\n"

  SLOW_COP = <<-RUBY
    # frozen_string_literal: true
    module RuboCop
      module Cop
        module CompatTest
          class SlowCop < %s
            def on_send(_node)
              File.write('.slow-marker', 'started')
              40.times { sleep 0.1 }
            end
          end
        end
      end
    end
  RUBY

  #: () -> void
  def initialize
    @rubocop = Gem.bin_path('rubocop', 'rubocop')
    @version = RuboCop::Version::STRING
    @failures = [] #: Array[String]
  end

  #: () -> void
  def run
    $stdout.sync = true
    puts "RuboCop #{@version} on Ruby #{RUBY_VERSION}"
    check_done
    check_error
    check_first_interrupt
    check_parallel
    check_noninspection
    check_silent_modes
    check_file_output
    check_idempotent_hooks
    if @failures.empty?
      puts 'Compatibility checks passed'
      return
    end
    @failures.each { |failure| warn "FAIL: #{failure}" }
    exit 1
  end

  private

  #: () -> void
  def check_done
    files = { '.rubocop.yml' => CONFIG, 'clean.rb' => CLEAN }
    enabled = run_rubocop(%w[clean.rb], files, 'force')
    disabled = run_rubocop(%w[clean.rb], files, 'off')
    assert_parity('clean', enabled, disabled)
    assert_exit('clean', enabled, 0)
    assert_working('clean', enabled)
    assert_final('clean', enabled, 'done')
  end

  #: () -> void
  def check_error
    files = { '.rubocop.yml' => CONFIG, 'bad.rb' => OFFENSE }
    enabled = run_rubocop(%w[bad.rb], files, 'force')
    disabled = run_rubocop(%w[bad.rb], files, 'off')
    assert_parity('offense', enabled, disabled)
    assert_exit('offense', enabled, 1)
    assert_working('offense', enabled)
    assert_final('offense', enabled, 'error')
  end

  #: () -> void
  def check_first_interrupt
    base = Gem::Version.new(@version) < Gem::Version.new('1.0.0') ? 'RuboCop::Cop::Cop' : 'RuboCop::Cop::Base'
    files = { '.rubocop.yml' => CONFIG, 'slow.rb' => CLEAN, 'slow_cop.rb' => format(SLOW_COP, base) }
    result = run_rubocop(%w[--require ./slow_cop.rb slow.rb], files, 'force', true)
    assert_final('first interrupt', result, 'idle')
  end

  #: () -> void
  def check_parallel
    files = { '.rubocop.yml' => CONFIG, 'a.rb' => OFFENSE, 'b.rb' => CLEAN }
    enabled = parallel_lane(files, 'force')
    disabled = parallel_lane(files, 'off')
    assert_parity('parallel cold', enabled.fetch(:cold), disabled.fetch(:cold))
    assert_parity('parallel warm', enabled.fetch(:warm), disabled.fetch(:warm))
    %i[cold warm].each do |phase|
      result = enabled.fetch(phase)
      assert_exit("parallel #{phase}", result, 1)
      assert_working("parallel #{phase}", result)
      assert_final("parallel #{phase}", result, 'error')
      assert_parallel_records("parallel #{phase}", result)
    end
    enabled_reused = enabled.fetch(:warm_cache) == enabled.fetch(:cold_cache)
    baseline_reused = disabled.fetch(:warm_cache) == disabled.fetch(:cold_cache)
    assert('parallel cold cache written', !enabled.fetch(:cold_cache).empty?)
    assert('parallel baseline cache written', !disabled.fetch(:cold_cache).empty?)
    assert('parallel cache behavior matches off baseline', enabled_reused == baseline_reused)
    if baseline_reused
      assert('parallel warm cache reused', enabled_reused)
    else
      puts "limit RuboCop #{@version} on Ruby #{RUBY_VERSION}: cold/warm root checksum changed with reporting off, so no cross-process cache hit is claimed"
    end
  end

  #: (untyped files, untyped mode) -> untyped
  def parallel_lane(files, mode)
    Dir.mktmpdir('rubocop osc7501 parallel ') do |directory|
      write_files(directory, files)
      cache_root = File.join(directory, 'cache')
      environment = { 'RUBYLIB' => ruby_lib, 'RUBOCOP_OSC7501' => mode, 'TERM' => nil, 'HOME' => directory,
                      'GEM_PATH' => Gem.path.join(File::PATH_SEPARATOR),
                      'XDG_CACHE_HOME' => cache_root, 'PARALLEL_PROCESSOR_COUNT' => '2' }
      command = command_for(%w[--parallel a.rb b.rb], true, true)
      cold = run_in(environment, command, directory)
      cold_cache = cache_snapshot(cache_root)
      warm = run_in(environment, command, directory)
      warm_cache = cache_snapshot(cache_root)
      { cold: cold, warm: warm, cold_cache: cold_cache, warm_cache: warm_cache }
    end
  end

  #: () -> void
  def check_noninspection
    files = { '.rubocop.yml' => CONFIG, 'clean.rb' => CLEAN }
    version = run_rubocop(%w[--version], files, 'force')
    assert_exit('version', version, 0)
    assert_frames('version', version, 0)
    assert('version native output', version[:output].include?(@version))

    listing = run_rubocop(%w[--list-target-files clean.rb], files, 'force')
    assert_exit('list targets', listing, 0)
    assert_frames('list targets', listing, 0)
    assert('list targets native output', listing[:output].include?('clean.rb'))
  end

  #: () -> void
  def check_silent_modes
    files = { '.rubocop.yml' => CONFIG, 'clean.rb' => CLEAN }
    off = run_rubocop(%w[clean.rb], files, 'off')
    auto = run_rubocop(%w[clean.rb], files, 'auto')
    unselected = run_rubocop(%w[clean.rb], files, 'force', false, false)
    assert_frames('off', off, 0)
    assert_frames('auto non-TTY', auto, 0)
    assert_frames('unselected', unselected, 0)
  end

  #: () -> void
  def check_file_output
    files = { '.rubocop.yml' => CONFIG, 'clean.rb' => CLEAN }
    result = run_rubocop(%w[--format progress --format RuboCop::OSC7501::Formatter --out status.txt clean.rb],
                         files, 'force', false, true, false)
    assert_exit('file output', result, 0)
    contents = result[:files]['status.txt'].to_s
    assert_final('file output', { output: contents }, 'done')
    assert_frames('file output stdout', result, 0)
  end

  #: () -> void
  def check_idempotent_hooks
    require 'rubocop/osc7501'
    require 'rubocop/osc7501' # rubocop:disable Lint/DuplicateRequire -- intentional idempotence check
    cli_private = RuboCop::CLI.private_method_defined?(:execute_runners)
    cli_hooks = RuboCop::CLI.ancestors.count { |ancestor| ancestor.to_s == 'RuboCop::OSC7501::Lifecycle::CLIHook' }
    runner_hooks = RuboCop::Runner.ancestors.count { |ancestor| ancestor.to_s == 'RuboCop::OSC7501::Lifecycle::RunnerHook' }
    assert('CLI execute_runners stays private', cli_private)
    assert('CLI hook installed exactly once', cli_hooks == 1)
    assert('Runner hook installed exactly once', runner_hooks == 1)
  end

  #: (untyped arguments, untyped files, untyped mode, ?untyped interrupt, ?untyped selected, ?untyped default_formatters) -> untyped
  def run_rubocop(arguments, files, mode, interrupt = false, selected = true, default_formatters = true)
    Dir.mktmpdir('rubocop osc7501 compat ') do |directory|
      write_files(directory, files)
      command = command_for(arguments, selected, default_formatters)
      environment = { 'RUBYLIB' => ruby_lib, 'RUBOCOP_OSC7501' => mode, 'TERM' => nil, 'HOME' => directory,
                      'GEM_PATH' => Gem.path.join(File::PATH_SEPARATOR) }
      output, error, status = interrupt ? run_interrupt(environment, command, directory) : capture(environment, command, directory)
      # @type var artifacts: Hash[String, String]
      artifacts = {}
      Dir.chdir(directory) { Dir['**/*'] }.each do |name|
        path = File.join(directory, name)
        artifacts[name] = File.binread(path) if File.file?(path)
      end
      { output: output, error: error, status: status, files: artifacts }
    end
  end

  #: () -> String
  def ruby_lib
    bundler = Gem.loaded_specs['bundler']
    bundler_lib = bundler.full_gem_path + '/lib' if bundler && Gem.path.none? { |path| bundler.full_gem_path.start_with?(path) }
    [LIB, bundler_lib].compact.join(File::PATH_SEPARATOR)
  end

  #: (untyped arguments, untyped selected, untyped default_formatters) -> Array[String]
  def command_for(arguments, selected, default_formatters)
    command = [RbConfig.ruby, @rubocop]
    command << '--no-server' if server_capable?
    command.concat(['--require', 'rubocop/osc7501']) if selected
    if selected && default_formatters
      command.concat(['--format', 'progress'])
      command.concat(['--format', 'RuboCop::OSC7501::Formatter'])
    end
    command.concat(arguments)
  end

  #: (untyped directory, untyped files) -> void
  def write_files(directory, files)
    files.each do |name, text|
      path = File.join(directory, name)
      FileUtils.mkdir_p(File.dirname(path))
      File.binwrite(path, text)
    end
  end

  #: (untyped environment, untyped command, untyped directory) -> untyped
  def run_in(environment, command, directory)
    output, error, status = capture(environment, command, directory)
    # @type var artifacts: Hash[String, String]
    artifacts = {}
    Dir.chdir(directory) { Dir['**/*'] }.each do |name|
      path = File.join(directory, name)
      artifacts[name] = File.binread(path) if File.file?(path)
    end
    { output: output, error: error, status: status, files: artifacts }
  end

  #: (untyped cache_root) -> Array[[String, Float, Integer]]
  def cache_snapshot(cache_root)
    # @type var snapshot: Array[[String, Float, Integer]]
    snapshot = Dir.chdir(cache_root) { Dir['**/*'] }.select { |name| File.file?(File.join(cache_root, name)) }
                                                   .map do |name|
      path = File.join(cache_root, name)
      [name, File.mtime(path).to_f, File.size(path)]
    end.sort
    snapshot
  rescue Errno::ENOENT
    []
  end

  #: () -> bool
  def server_capable?
    Gem::Version.new(@version) >= Gem::Version.new('1.31.0')
  end

  #: (untyped environment, untyped command, untyped directory) -> void
  def report_spawn_once(environment, command, directory)
    return if @reported_spawn || !ENV.key?('CI')

    @reported_spawn = true
    bundler = Gem.loaded_specs['bundler']
    bundler_path = bundler ? bundler.full_gem_path : 'none'
    setup = bundler ? File.join(bundler_path, 'lib', 'bundler', 'setup.rb') : 'none'
    keys = %w[GEM_PATH RUBYLIB RUBYOPT BUNDLE_GEMFILE BUNDLE_PATH BUNDLE_APP_CONFIG]
    effective = keys.map do |key|
      "#{key}=#{environment.key?(key) ? environment[key].inspect : ENV[key].inspect}"
    end
    puts "compat spawn: ruby=#{RbConfig.ruby} dir=#{directory} command=#{command.join(' ')}"
    puts "compat bundler=#{bundler_path} setup=#{setup} exists=#{setup == 'none' ? false : File.exist?(setup)} " \
         "readable=#{setup == 'none' ? false : File.readable?(setup)} computed_rubylib=#{ruby_lib}"
    puts "compat env: #{effective.join(' ')}"
  end

  #: (untyped environment, untyped command, untyped directory) -> untyped
  def capture(environment, command, directory)
    report_spawn_once(environment, command, directory)
    Open3.popen3(environment, *command, chdir: directory, pgroup: true) do |input, output, error, waiter|
      input.close
      readers = [output, error].map { |stream| Thread.new { stream.read } }
      begin
        raise 'RuboCop subprocess timeout' unless waiter.join(30)
        [readers[0].value, readers[1].value, waiter.value]
      ensure
        unless waiter.join(0)
          Process.kill('KILL', -waiter.pid)
          waiter.join
        end
        readers.each(&:join)
      end
    end
  end

  #: (untyped environment, untyped command, untyped directory) -> untyped
  def run_interrupt(environment, command, directory)
    report_spawn_once(environment, command, directory)
    output_path = File.join(directory, 'compat-stdout')
    error_path = File.join(directory, 'compat-stderr')
    pid = Process.spawn(environment, *command, chdir: directory, out: output_path, err: error_path, pgroup: true)
    status = nil
    begin
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 30
      loop do
        output = File.exist?(output_path) ? File.read(output_path) : ''
        break if output.include?('state=working') && File.exist?(File.join(directory, '.slow-marker'))
        waited, child_status = Process.waitpid2(pid, Process::WNOHANG)
        if waited
          status = child_status
          raise "RuboCop interrupt child exited before working (#{child_status.exitstatus}): #{output} #{File.read(error_path)}"
        end
        if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
          raise "RuboCop interrupt startup timeout: #{output} #{File.read(error_path)}"
        end
        sleep 0.02
      end
      Process.kill('INT', -pid)
      _waited, status = Process.waitpid2(pid)
    ensure
      unless status
        begin
          Process.kill('KILL', -pid)
        rescue Errno::ESRCH
          nil
        end
        Process.waitpid(pid)
      end
    end
    [File.read(output_path), File.read(error_path), status]
  end

  #: (untyped output) -> untyped
  def frames(output)
    output.scan(/\e\]7501;([^\e]*)\e\\/).map do |(body)|
      body.split(':').map do |field|
        key, value = field.split('=', 2)
        [key, %w[title msg].include?(key) ? value.unpack('m0').first.force_encoding('UTF-8') : value]
      end.to_h
    end
  end

  #: (untyped output) -> untyped
  def without_frames(output)
    output.gsub(/\e\]7501;[^\e]*\e\\/, '')
  end

  #: (untyped label, untyped enabled, untyped disabled) -> void
  def assert_parity(label, enabled, disabled)
    assert("#{label} stdout parity", without_frames(enabled[:output]) == without_frames(disabled[:output]))
    assert("#{label} stderr parity", enabled[:error] == disabled[:error])
    assert("#{label} status parity", enabled[:status].exitstatus == disabled[:status].exitstatus)
  end

  #: (untyped label, untyped result, untyped expected) -> void
  def assert_exit(label, result, expected)
    assert("#{label} exit #{expected}", result[:status].exitstatus == expected)
  end

  #: (untyped label, untyped result) -> void
  def assert_parallel_records(label, result)
    records = frames(result[:output])
    roots = records.select { |record| record['msg'] == 'Inspecting files' }
    terminals = records.select { |record| %w[done error idle].include?(record['state']) }
    assert("#{label} one root stream", roots.length == 1 && records.all? { |record| record['app'] == 'rubocop' })
    assert("#{label} one final frame", terminals.length == 1)
    final = terminals.last
    assert("#{label} aggregate counts", final && final['msg'] =~ %r{2/2 file results, [1-9]\d* reported offenses})
  end

  #: (untyped label, untyped result) -> void
  def assert_working(label, result)
    working = frames(result[:output]).select { |record| record['state'] == 'working' }
    assert("#{label} working record", !working.empty? && working.first['app'] == 'rubocop')
  end

  #: (untyped label, untyped result, untyped expected) -> void
  def assert_final(label, result, expected)
    output = result[:output]
    final = frames(output).select { |record| %w[done error idle].include?(record['state']) }.last
    assert("#{label} final #{expected}", final && final['state'] == expected)
  end

  #: (untyped label, untyped result, untyped expected) -> void
  def assert_frames(label, result, expected)
    assert("#{label} frame count #{expected}", frames(result[:output]).length == expected)
  end

  #: (String, untyped) -> void
  def assert(label, condition)
    if condition
      puts "ok #{label}"
    else
      @failures << label
      warn "FAIL: #{label}"
    end
  end
end

Compat.new.run if $PROGRAM_NAME == __FILE__
