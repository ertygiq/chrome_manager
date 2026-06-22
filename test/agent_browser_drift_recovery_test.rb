#!/usr/bin/env ruby
# frozen_string_literal: true

ENV['BUNDLE_GEMFILE'] ||= File.expand_path('../Gemfile', __dir__)
require 'bundler/setup'
require_relative '../lib/chrome_manager'

# Destructive integration test: launches real Chrome, uses agent-browser, and
# kills agent-browser daemons to simulate the observed drift/recovery behavior.
# Run explicitly:
#   RUN_CHROME_MANAGER_INTEGRATION=1 ruby test/agent_browser_drift_recovery_test.rb
if ENV['RUN_CHROME_MANAGER_INTEGRATION'] != '1'
  warn 'SKIP: set RUN_CHROME_MANAGER_INTEGRATION=1 to run real Chrome integration tests'
  exit 0
end

manager = ChromeManager.new
lease = nil

def assert(condition, message)
  raise "ASSERTION FAILED: #{message}" unless condition
end

def kill_agent_browser_daemons
  pids = `pgrep -f agent-browser-darwin-arm64 2>/dev/null`.split.map(&:to_i)
  pids.each do |pid|
    Process.kill('TERM', pid)
  rescue Errno::ESRCH
    nil
  end
  sleep 2
end

def port_from_cdp_url(url)
  url&.match(%r{127\.0\.0\.1:(\d+)})&.[](1)&.to_i
end

begin
  system('agent-browser', 'close', '--all', out: File::NULL, err: File::NULL)
  manager.gc

  lease = manager.lease(connect_agent_browser: true)

  initial = manager.check(lease.fetch('id'))
  assert(initial.fetch('connected') == true, "initial check should be connected: #{initial.inspect}")

  kill_agent_browser_daemons

  drifted = manager.check(lease.fetch('id'))
  assert(drifted.fetch('connected') == false, "drifted check should be disconnected: #{drifted.inspect}")
  assert(port_from_cdp_url(drifted['cdpUrl']) != lease.fetch('port'), "drifted CDP port should differ: #{drifted.inspect}")

  recovered = manager.connect_agent_browser(lease.fetch('id'))
  assert(recovered.fetch('connected') == true, "recovered check should be connected: #{recovered.inspect}")
  assert(port_from_cdp_url(recovered.fetch('cdpUrl')) == lease.fetch('port'), "recovered CDP port should match lease: #{recovered.inspect}")

  puts 'PASS: agent-browser drift is detected and recovered'
ensure
  begin
    manager.release(lease.fetch('id')) if lease
  rescue StandardError
    nil
  end
  system('agent-browser', 'close', '--all', out: File::NULL, err: File::NULL)
end
