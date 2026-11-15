# frozen_string_literal: true
# rbs_inline: enabled

# Decodes and strips OSC 7501 frames consistently across in-suite checks.
module FrameHelpers
  FRAME = /\e\]7501;([^\e]*)\e\\/

  #: (String) -> Array[Hash[String, String]]
  def self.frames_from(output)
    output.scan(FRAME).map do |(body)|
      body.split(':').map do |field|
        key, value = field.split('=', 2)
        [key, %w[title msg].include?(key) ? value.unpack('m0').first.force_encoding('UTF-8') : value]
      end.to_h
    end
  end

  #: (String) -> String
  def self.without_frames(output)
    output.gsub(/\e\](?:2|7501);[^\e]*\e\\/, '')
  end

  #: (String) -> Array[String]
  def self.titles_from(output)
    output.scan(/\e\]2;([^\e]*)\e\\/).map { |(title)| title.force_encoding('UTF-8') }
  end

  #: (String) -> Array[Hash[String, String]]
  def frames(output)
    FrameHelpers.frames_from(output)
  end

  #: (String) -> String
  def without_frames(output)
    FrameHelpers.without_frames(output)
  end

  #: (String) -> Array[String]
  def titles(output)
    FrameHelpers.titles_from(output)
  end
end
