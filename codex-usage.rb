#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative "lib/codex_usage/cli"

exit CodexUsage::CLI.new.run(ARGV) if $PROGRAM_NAME == __FILE__
