# frozen_string_literal: true
# rbs_inline: enabled

require 'spec_helper'
require 'bundler'
require 'fileutils'
require 'open3'
require 'rubygems/installer'
require 'rubygems/package'
require 'tmpdir'

# rubocop:disable RSpec/DescribeClass -- package contract does not map to one class
RSpec.describe 'Canonical package', :aggregate_failures do
  let(:root) { File.expand_path('../..', __dir__) }
  let(:directory) { Dir.mktmpdir('rubocop-osc7501-package-') }
  let(:specification) { Gem::Specification.load(File.join(root, 'rubocop-osc7501.gemspec')) }
  let(:home) { File.join(directory, 'gems') }
  let(:package_path) { File.join(directory, 'pkg', "#{specification.full_name}.gem") }

  before do
    (specification.files + %w[Rakefile rubocop-osc7501.gemspec]).each do |path|
      source = File.join(root, path)
      next unless File.file?(source)

      destination = File.join(directory, path)
      FileUtils.mkdir_p(File.dirname(destination))
      FileUtils.cp(source, destination)
    end
    output, error, status = Open3.capture3({ 'BUNDLE_GEMFILE' => File.join(root, 'Gemfile') },
                                           'bundle', 'exec', 'rake', 'package', chdir: directory)
    raise "#{output}\n#{error}" unless status.success?

    Gem::Installer.at(package_path, install_dir: home, ignore_dependencies: true).install
  end

  after { FileUtils.remove_entry(directory) }

  it 'declares the compatibility floor and RuboCop as the sole runtime dependency' do
    expect(specification.required_ruby_version).to eq(Gem::Requirement.new('>= 2.1'))
    expect(specification.runtime_dependencies.map(&:name)).to eq(['rubocop'])
    expect(specification.runtime_dependencies.first.requirement).to eq(Gem::Requirement.new('>= 0.52.0'))
  end

  it 'packages exactly the generated runtime signatures' do
    signatures = Dir[File.join(root, 'lib/**/*.rb')].map do |path|
      path.delete_prefix("#{root}/lib/").sub(/\.rb\z/, '.rbs').prepend('sig/')
    end
    expect(Gem::Package.new(package_path).spec.files.grep(/\.rbs\z/)).to match_array(signatures)
  end

  it 'validates installed consumer signatures by gem name' do
    environment = { 'GEM_PATH' => ([home] + Gem.path).join(File::PATH_SEPARATOR) }
    output, error, status = Bundler.with_unbundled_env do
      Open3.capture3(environment, 'rbs', '-r', 'stringio', '-r', 'rubocop-osc7501', 'validate', chdir: directory)
    end
    expect(status.success?).to be(true), "#{output}\n#{error}"
  end

  it 'loads the installed entrypoint and formatter without development companions' do
    output, error, status = load_installed
    expect(status.success?).to be(true), "#{output}\n#{error}"
  end

  #: () -> String
  def installed_source
    <<~RUBY
      require 'rubocop/osc7501'
      abort 'Wrong entrypoint' unless $LOADED_FEATURES.any? { |path| path.end_with?('/lib/rubocop/osc7501.rb') }
      abort 'Companion loaded' if Gem.loaded_specs.keys.any? { |name| name.start_with?('rspec', 'rake', 'thor') }
      abort 'Wrong formatter' unless RuboCop::OSC7501::Formatter < RuboCop::Formatter::BaseFormatter
    RUBY
  end

  #: () -> [String, String, Process::Status]
  def load_installed
    environment = { 'GEM_PATH' => ([home] + Gem.path).join(File::PATH_SEPARATOR),
                    'RUBYOPT' => nil, 'RUBYLIB' => nil, 'BUNDLE_GEMFILE' => nil }
    Bundler.with_unbundled_env do
      Open3.capture3(environment, Gem.ruby, '-e', installed_source, chdir: directory)
    end
  end
end
# rubocop:enable RSpec/DescribeClass
