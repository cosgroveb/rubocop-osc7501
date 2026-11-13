# frozen_string_literal: true
# rbs_inline: enabled

require 'spec_helper'
require 'tmpdir'

class TtyOutput < StringIO
  #: () -> bool
  def tty?
    true
  end
end

class BrokenOutput
  #: (String) -> Integer
  def write(_text)
    raise Errno::EPIPE
  end

  #: () -> nil
  def flush
    nil
  end

  #: () -> bool
  def tty?
    false
  end
end

class ExplodingTty
  #: () -> bool
  def tty?
    raise IOError
  end
end

RSpec.describe RuboCop::OSC7501::Writer do
  let(:output) { StringIO.new }

  #: (StringIO, String) -> RuboCop::OSC7501::Writer
  def writer(io, mode = 'force')
    described_class.new(io, mode: mode)
  end

  it 'emits a complete decodable root frame with RuboCop identity' do
    result = writer(output).emit(state: 'working', msg: "Inspecting\nfiles")
    expect(result).to be_nil
    record = frames(output.string).last
    expect(record).to include('app' => 'rubocop', 'title' => 'RuboCop', 'state' => 'working',
                              'msg' => 'Inspecting files')
    expect(record).not_to have_key('id')
    expect(record).not_to have_key('progress')
    expect(record).not_to have_key('kind')
    expect(output.string).to start_with("\e]7501;").and(end_with("\e\\"))
  end

  it 'sanitizes terminal formatting, controls and invalid bytes into one line' do
    binary = "broken-\xE2\x28\xA1".dup.force_encoding('BINARY')
    writer(output).emit(state: 'working', msg: "\e[31mInspecting\e[0m\t\x01#{binary}\nnext")
    expect(frames(output.string).last['msg']).to eq('Inspecting broken-�(� next')
  end

  it 'bounds decoded messages to 2048 UTF-8 bytes without splitting characters' do
    writer(output).emit(state: 'working', msg: 'é' * 3000)
    emitted = frames(output.string).last['msg']
    expect(emitted).to be_valid_encoding
    expect(emitted.bytesize).to eq(2048)
    expect(emitted).to eq('é' * 1024)
  end

  it 'bounds sanitization input even when removed controls leave room' do
    writer(output).emit(state: 'working', msg: "#{"\0" * 3072}discarded")
    expect(frames(output.string).last['msg']).to eq('')
  end

  describe 'modes' do
    it 'emits in force mode without a TTY' do
      instance = writer(output, 'force')
      expect(instance.enabled?).to eq(true)
      expect { instance.emit(state: 'working', msg: 'x') }.to(change { output.string })
    end

    it 'stays silent in off mode' do
      instance = writer(output, 'off')
      expect(instance.enabled?).to eq(false)
      expect { instance.emit(state: 'working', msg: 'x') }.not_to(change { output.string })
    end

    it 'stays silent in auto mode without a TTY' do
      instance = writer(output, 'auto')
      expect(instance.enabled?).to eq(false)
      expect { instance.emit(state: 'working', msg: 'x') }.not_to(change { output.string })
    end

    it 'stays silent in auto mode with a dumb terminal' do
      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with('TERM').and_return('dumb')
      tty = TtyOutput.new
      expect(writer(tty, 'auto').enabled?).to eq(false)
      expect { writer(tty, 'auto').emit(state: 'working', msg: 'x') }.not_to(change { tty.string })
    end

    it 'emits in auto mode on a TTY with a usable TERM' do
      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with('TERM').and_return('xterm-256color')
      tty = TtyOutput.new
      writer(tty, 'auto').emit(state: 'working', msg: 'x')
      expect(frames(tty.string).last['state']).to eq('working')
    end

  end

  describe 'output ownership' do
    it 'duplicates an enabled File so a final frame survives the original closing' do
      Dir.mktmpdir('rubocop osc7501 writer ') do |directory|
        path = File.join(directory, 'report.txt')
        file = File.open(path, 'w')
        instance = described_class.new(file, mode: 'force')
        expect(instance.enabled?).to eq(true)
        file.write('ordinary')
        file.close
        instance.emit(state: 'done', msg: 'Inspection complete')
        instance.close
        expect(File.read(path)).to eq("ordinary#{frame_text('done', 'Inspection complete')}")
      end
    end

    it 'keeps an ordinary borrowed stream open and writes to it directly' do
      instance = writer(output)
      instance.emit(state: 'done', msg: 'Inspection complete')
      instance.close
      expect(output).not_to be_closed
      expect(frames(output.string).last['state']).to eq('done')
    end

    it 'allocates no duplicate when reporting is disabled' do
      Dir.mktmpdir('rubocop osc7501 disabled ') do |directory|
        file = File.open(File.join(directory, 'report.txt'), 'w')
        instance = described_class.new(file, mode: 'off')
        expect(instance.enabled?).to eq(false)
        instance.close
        expect(file).not_to be_closed
        file.close
      end
    end

    it 'closes only its owned duplicate, leaving the original File untouched' do
      Dir.mktmpdir('rubocop osc7501 owned ') do |directory|
        file = File.open(File.join(directory, 'report.txt'), 'w')
        instance = described_class.new(file, mode: 'force')
        instance.close
        expect(file).not_to be_closed
        file.close
      end
    end
  end

  describe 'reporting IO failures' do
    it 'disables reporting on write failure without raising' do
      instance = writer(BrokenOutput.new)
      expect { instance.emit(state: 'working', msg: 'x') }.not_to raise_error
      expect(instance.enabled?).to eq(false)
      expect { instance.emit(state: 'done', msg: 'Inspection complete') }.not_to raise_error
    end

    it 'disables reporting when TTY detection fails' do
      instance = described_class.new(ExplodingTty.new, mode: 'auto')
      expect(instance.enabled?).to eq(false)
      expect { instance.emit(state: 'working', msg: 'x') }.not_to raise_error
    end

    it 'disables reporting when a buffered flush fails' do
      output.define_singleton_method(:flush) { raise IOError, 'flush failed' }
      instance = writer(output)
      expect { instance.emit(state: 'working', msg: 'x') }.not_to raise_error
      expect(instance.enabled?).to eq(false)
      expect(frames(output.string).map { |record| record['state'] }).to eq(['working'])
    end

    it 'does not replace a caller exception raised around emit' do
      allow(output).to receive(:write).and_raise(IOError)
      instance = writer(output)
      expect do
        begin
          instance.emit(state: 'working', msg: 'x')
          raise 'caller failure'
        end
      end.to raise_error('caller failure')
    end
  end

  #: (String, String) -> String
  def frame_text(state, msg)
    "\e]7501;app=rubocop:title=UnVib0NvcA==:state=#{state}:msg=#{["#{msg}"].pack('m0')}\e\\"
  end
end
