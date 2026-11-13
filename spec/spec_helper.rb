# frozen_string_literal: true
# rbs_inline: enabled

require 'stringio'
require 'rubocop/osc7501'
require_relative 'support/frame_helpers'

RSpec.configure do |config|
  config.include FrameHelpers
  config.order = :random
  Kernel.srand config.seed
end
