# frozen_string_literal: true
# rbs_inline: enabled

require 'fileutils'
require 'open3'
require 'rbconfig'
require 'tmpdir'
require_relative 'frame_helpers'

# Runs isolated RuboCop commands with bounded timeouts and reaps every child.
class ProcessHelpers
  ROOT = File.expand_path('../..', __dir__)

  #: (argv: Array[String], ?mode: String, ?files: Hash[String, String], ?environment: Hash[String, String?]) -> Hash[Symbol, untyped]
  def self.run(argv:, mode: 'force', files: {}, environment: {})
    Dir.mktmpdir('rubocop osc7501 ') do |directory|
      files.each do |name, text|
        path = File.join(directory, name)
        FileUtils.mkdir_p(File.dirname(path))
        File.binwrite(path, text)
      end
      initial = files.keys
      environment = { 'BUNDLE_GEMFILE' => File.join(ROOT, 'Gemfile'),
                      'RUBYLIB' => File.join(ROOT, 'lib'),
                      'RUBOCOP_OSC7501' => mode, 'TERM' => nil,
                      'HOME' => directory }.merge(environment)
      command = [RbConfig.ruby, '-S', 'bundle', 'exec', 'rubocop', '--no-server', *argv]
      output, error, status = capture(environment, command, directory)
      artifacts = (initial + Dir.chdir(directory) { Dir['**/*'] }).uniq.each_with_object({}) do |name, result|
        path = File.join(directory, name)
        result[name] = File.binread(path) if File.file?(path)
      end
      { frames: FrameHelpers.frames_from(output), stdout: FrameHelpers.without_frames(output), stderr: error, status: status,
        artifacts: artifacts }
    end
  end

  #: (String source, ?mode: String, ?files: Hash[String, String]) -> Hash[Symbol, untyped]
  def self.run_ruby(source, mode: 'force', files: {})
    Dir.mktmpdir('rubocop osc7501 ruby ') do |directory|
      files.each do |name, text|
        path = File.join(directory, name)
        FileUtils.mkdir_p(File.dirname(path))
        File.binwrite(path, text)
      end
      File.write(File.join(directory, 'runner.rb'), source)
      environment = { 'BUNDLE_GEMFILE' => File.join(ROOT, 'Gemfile'),
                      'RUBYLIB' => File.join(ROOT, 'lib'),
                      'RUBOCOP_OSC7501' => mode, 'TERM' => nil,
                      'HOME' => directory }
      command = [RbConfig.ruby, 'runner.rb']
      output, error, status = capture(environment, command, directory)
      artifacts = Dir.chdir(directory) { Dir['**/*'] }.each_with_object({}) do |name, result|
        path = File.join(directory, name)
        result[name] = File.binread(path) if File.file?(path)
      end
      { frames: FrameHelpers.frames_from(output), stdout: FrameHelpers.without_frames(output), stderr: error, status: status,
        artifacts: artifacts }
    end
  end

  #: (Hash[String, String?], Array[String], String) -> [String, String, Process::Status]
  def self.capture(environment, command, directory)
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
  private_class_method :capture
end
