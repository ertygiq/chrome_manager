#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'open3'

# Integration test for the exact agent-facing CLI flow.
# Run explicitly:
#   RUN_CHROME_MANAGER_INTEGRATION=1 ruby test/cli_connect_flow_test.rb
if ENV['RUN_CHROME_MANAGER_INTEGRATION'] != '1'
  warn 'SKIP: set RUN_CHROME_MANAGER_INTEGRATION=1 to run real Chrome integration tests'
  exit 0
end

ROOT = File.expand_path('..', __dir__)
CHROME_MANAGER = File.join(ROOT, 'bin', 'chrome-manager')

def run!(*cmd)
  out, err, status = Open3.capture3(*cmd)
  raise "command failed: #{cmd.join(' ')}\nstdout:\n#{out}\nstderr:\n#{err}" unless status.success?

  out
end

def assert(condition, message)
  raise "ASSERTION FAILED: #{message}" unless condition
end

def check(session)
  JSON.parse(run!(CHROME_MANAGER, 'check', session))
end

lease = nil

begin
  system('agent-browser', 'close', '--all', out: File::NULL, err: File::NULL)
  system(CHROME_MANAGER, 'gc', out: File::NULL, err: File::NULL)

  lease = JSON.parse(run!(CHROME_MANAGER, 'lease', '--connect-agent-browser'))
  session = lease.fetch('session')

  initial = check(session)
  assert(initial.fetch('connected') == true, "expected connected immediately after lease --connect-agent-browser: #{initial.inspect}")

  run!('agent-browser', '--session', session, 'open', 'about:blank')

  after_open = check(session)
  assert(after_open.fetch('connected') == true, "expected still connected after agent-browser open: #{after_open.inspect}")

  puts 'PASS: CLI lease --connect-agent-browser flow stays connected'
ensure
  begin
    run!(CHROME_MANAGER, 'release', lease.fetch('session')) if lease
  rescue StandardError
    nil
  end
  system('agent-browser', 'close', '--all', out: File::NULL, err: File::NULL)
end
