# frozen_string_literal: true

require 'bundler/setup'
require 'tmpdir'
require 'stringio'
require_relative '../lib/chrome_manager'

# Stub process operations so these tests never launch or stop a real browser.
class BgChrome
  class << self
    attr_accessor :last_options, :started
  end

  def initialize(**options)
    self.class.last_options = options
  end

  def start
    self.class.started = true
  end

  def main_pid
    12345
  end
end

class ChromeManager
  def pids_for(_profile)
    []
  end

  def port_open?(_port)
    false
  end

  def connect_agent_browser(id)
    raise 'unexpected lease ID' unless id == 'browser-1'
    $proxy_test_connected = true
  end
end

def assert(condition, message)
  raise message unless condition
end

Dir.mktmpdir do |home|
  manager = ChromeManager.new(home: home)
  lease = manager.lease
  assert(lease.key?('proxy') && lease['proxy'].nil?, 'default lease must report a null proxy')
  assert(BgChrome.last_options[:proxy].nil?, 'default lease must not set a proxy')
  %w[http://127.0.0.1:8080 socks5://127.0.0.1:1080].each do |proxy|
    BgChrome.started = false
    lease = manager.lease(proxy: proxy)
    assert(lease['proxy'] == proxy, 'lease must report its proxy')
    listing_manager = ChromeManager.new(home: home)
    def listing_manager.cleanup_dead(leases)
      leases
    end
    assert(listing_manager.list.last['proxy'] == proxy, 'list must report the persisted proxy')
    assert(BgChrome.last_options[:proxy] == proxy, 'proxy must reach Chrome launcher unchanged')
    assert(BgChrome.started, 'Chrome must be started')
  end
end

original_stdout = $stdout
original_argv = ARGV.dup
original_home = ENV['CHROME_MANAGER_HOME']
begin
  [
    ['lease'],
    ['lease', '--proxy', 'http://127.0.0.1:8080'],
    ['lease', '--connect-agent-browser', '--proxy=socks5://127.0.0.1:1080']
  ].each do |args|
    Dir.mktmpdir do |home|
      ENV['CHROME_MANAGER_HOME'] = home
      ARGV.replace(args)
      $stdout = StringIO.new
      $proxy_test_connected = false
      load File.expand_path('../bin/chrome-manager', __dir__)
      expected = args.last.include?('socks5:') ? 'socks5://127.0.0.1:1080' : (args.length > 1 ? args.last : nil)
      assert(BgChrome.last_options[:proxy] == expected, 'CLI must forward proxy')
      assert(JSON.parse($stdout.string)['id'] == 'browser-1', 'CLI must return lease JSON')
      assert($proxy_test_connected == args.include?('--connect-agent-browser'), 'connect option must still work')
    end
  end
ensure
  $stdout = original_stdout
  ARGV.replace(original_argv)
  ENV['CHROME_MANAGER_HOME'] = original_home
end

puts 'PASS: optional proxy reaches Chrome launcher through Ruby and CLI'
