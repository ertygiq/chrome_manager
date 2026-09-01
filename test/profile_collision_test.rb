#!/usr/bin/env ruby
# frozen_string_literal: true

require 'tmpdir'
require_relative '../lib/chrome_manager'

class ChromeManagerWithActiveProfiles < ChromeManager
  def initialize(active_profiles:, **kwargs)
    @active_profiles = active_profiles
    super(**kwargs)
  end

  private

  def pids_for(user_data_dir)
    @active_profiles.include?(File.basename(user_data_dir)) ? [12_345] : []
  end
end

def assert(condition, message)
  raise "ASSERTION FAILED: #{message}" unless condition
end

Dir.mktmpdir do |home|
  manager = ChromeManagerWithActiveProfiles.new(
    home: home,
    active_profiles: ['browser-1']
  )

  leases = [{ 'id' => 'browser-2' }]
  index = manager.send(:next_index, leases)

  assert(index == 3, "expected active orphan browser-1 and leased browser-2 to be skipped, got browser-#{index}")
end

puts 'PASS: active profiles missing from lease state are not reused'
