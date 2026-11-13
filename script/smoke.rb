# frozen_string_literal: true
# rbs_inline: enabled

require 'bundler'
require 'open3'
require 'rubygems/installer'
require 'tmpdir'

# Run packaged code with an isolated gem home and no checkout load paths.
class InstalledSmoke
  # @rbs @package: String
  # @rbs @entrypoint: String
  # @rbs @rubocop: String

  #: (String) -> void
  def initialize(package)
    @package = File.expand_path(package)
  end

  #: () -> void
  def run
    Dir.mktmpdir('rubocop-osc7501-installed-') do |directory|
      rubocop = Gem::Specification.find_by_name('rubocop')
      install_dependencies(directory, rubocop, {})
      installed_rubocop = install(rubocop.cache_file, directory)
      @rubocop = File.join(installed_rubocop.full_gem_path, installed_rubocop.bindir, 'rubocop')
      installed = install(@package, directory)
      @entrypoint = File.realpath(File.join(installed.full_gem_path, 'lib/rubocop/osc7501.rb'))
      check(directory, "# frozen_string_literal: true\n", 0)
      check(directory, "def bad( x )\n  x+1\nend\n", 1)
    end
    puts 'Installed RuboCop clean and offending inspections verified with no companion gems'
  end

  private

  #: (String, Gem::Specification, Hash[String, bool] seen) -> void
  def install_dependencies(directory, specification, seen)
    specification.runtime_dependencies.each do |dependency|
      next if seen[dependency.name]

      installed = Gem::Specification.find_by_name(dependency.name)
      next unless installed

      seen[dependency.name] = true
      if File.file?(installed.cache_file)
        install(installed.cache_file, directory)
      elsif !installed.default_gem?
        raise "Missing cached gem for #{installed.full_name}"
      end
      install_dependencies(directory, installed, seen)
    end
  end

  #: (String, String) -> Gem::Specification
  def install(package, directory)
    constructor = Gem::Installer.respond_to?(:at) ? :at : :new
    Gem::Installer.public_send(constructor, package, install_dir: directory, ignore_dependencies: true).install
  end

  #: (String, String, Integer) -> void
  def check(directory, source, expected_status)
    check_source = "abort 'Wrong installed entrypoint' unless $LOADED_FEATURES.include?(#{@entrypoint.inspect})\n"
    check_source += "abort 'Companion loaded' if Gem.loaded_specs.keys.any? { |name| name.start_with?('rspec', 'rake', 'thor') }\n"
    File.write(File.join(directory, 'check.rb'), check_source)
    File.write(File.join(directory, 'sample.rb'), source)
    configuration = "AllCops:\n  NewCops: disable\n"
    File.write(File.join(directory, '.rubocop.yml'), configuration)
    # @type var environment: Hash[String, String?]
    environment = { 'GEM_HOME' => directory, 'GEM_PATH' => directory, 'HOME' => directory,
                    'RUBYOPT' => nil, 'RUBYLIB' => nil, 'BUNDLE_GEMFILE' => nil,
                    'RUBOCOP_OSC7501' => 'force', 'TERM' => nil }
    command = [Gem.ruby, @rubocop, '--no-server', '--require', 'rubocop/osc7501',
               '--require', './check.rb', '--format', 'progress',
               '--format', 'RuboCop::OSC7501::Formatter', 'sample.rb']
    clean = Bundler.respond_to?(:with_unbundled_env) ? :with_unbundled_env : :with_clean_env
    output, error, status = Bundler.public_send(clean) do
      Open3.capture3(environment, *command, chdir: directory)
    end
    raise "Wrong process outcome: #{output}\n#{error}" unless status.exitstatus == expected_status

    records = output.scan(/\e\]7501;([^\e]*)\e\\/).map do |(body)|
      body.split(':').map { |field| field.split('=', 2) }.to_h
    end
    terminal = records.select { |record| %w[done error idle].include?(record['state']) }.last
    expected = expected_status.zero? ? 'done' : 'error'
    raise 'Wrong final outcome' unless terminal && terminal['state'] == expected
    raise 'Unexpected progress' if records.any? { |record| record.key?('progress') }
    ordinary = expected_status.zero? ? /1 file inspected/ : /\d+ offenses? detected/
    raise "Missing ordinary output: #{output} #{error}" unless output =~ ordinary
  end
end

InstalledSmoke.new(ARGV.fetch(0)).run if $PROGRAM_NAME == __FILE__
