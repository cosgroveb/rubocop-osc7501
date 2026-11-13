# frozen_string_literal: true
# rbs_inline: enabled

require 'rubocop'
require_relative 'osc7501/version'
require_relative 'osc7501/writer'
require_relative 'osc7501/lifecycle'
require_relative 'osc7501/formatter'

module RuboCop
  module OSC7501
    # Requiring this entrypoint registers the formatter and installs inert
    # lifecycle hooks once. Only a selected supported inspection reports.
    Lifecycle.install!
  end
end
