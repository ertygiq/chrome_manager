# frozen_string_literal: true

require 'json'
require 'fileutils'
require 'socket'
require 'time'
require 'bg_chrome'

class ChromeManager
  DEFAULT_HOME = File.expand_path('~/.chrome-manager')
  DEFAULT_BASE_PORT = 9222
  NULL_LOGGER = Object.new.tap { |o| def o.info(_msg); end }

  def initialize(home: ENV.fetch('CHROME_MANAGER_HOME', DEFAULT_HOME), base_port: DEFAULT_BASE_PORT)
    @home = File.expand_path(home)
    @base_port = base_port.to_i
    @state_path = File.join(@home, 'leases.json')
    @profiles_dir = File.join(@home, 'profiles')
    FileUtils.mkdir_p(@profiles_dir)
  end

  def lease
    with_lock do
      leases = load_leases
      leases = cleanup_dead(leases)

      n = next_index(leases)
      id = "browser-#{n}"
      port = next_port(leases)
      user_data_dir = File.join(@profiles_dir, id)
      session = id

      chrome = BgChrome.new(
        user_data_dir: user_data_dir,
        cdp_port: port,
        agent_browser_session: session,
        logger: NULL_LOGGER,
        auto_stop: false
      )
      chrome.start

      lease = {
        'id' => id,
        'session' => session,
        'port' => port,
        'cdp' => "http://127.0.0.1:#{port}",
        'pid' => chrome.main_pid,
        'userDataDir' => user_data_dir,
        'status' => 'leased',
        'createdAt' => Time.now.utc.iso8601
      }
      leases << lease
      save_leases(leases)
      lease
    end
  end

  def list
    with_lock do
      leases = cleanup_dead(load_leases)
      save_leases(leases)
      leases
    end
  end

  def release(id)
    with_lock do
      leases = load_leases
      lease = leases.find { |l| l['id'] == id || l['session'] == id || l['port'].to_s == id.to_s }
      raise "unknown lease: #{id}" unless lease

      BgChrome.new(
        user_data_dir: lease.fetch('userDataDir'),
        cdp_port: lease.fetch('port'),
        agent_browser_session: lease['session'],
        logger: NULL_LOGGER,
        auto_stop: false
      ).stop

      leases.delete(lease)
      save_leases(leases)
      { 'released' => true, 'id' => lease['id'] }
    end
  end

  def gc
    with_lock do
      before = load_leases
      after = cleanup_dead(before)
      save_leases(after)
      { 'removed' => before.size - after.size, 'active' => after.size }
    end
  end

  private

  def with_lock
    FileUtils.mkdir_p(@home)
    File.open(File.join(@home, 'lock'), File::RDWR | File::CREAT, 0o600) do |f|
      f.flock(File::LOCK_EX)
      yield
    end
  end

  def load_leases
    return [] unless File.exist?(@state_path)

    JSON.parse(File.read(@state_path))
  rescue JSON::ParserError
    []
  end

  def save_leases(leases)
    tmp = "#{@state_path}.tmp"
    File.write(tmp, JSON.pretty_generate(leases) + "\n")
    File.rename(tmp, @state_path)
  end

  def cleanup_dead(leases)
    leases.select { |l| port_open?(l['port']) || pids_for(l['userDataDir']).any? }
  end

  def next_index(leases)
    used = leases.map { |l| l['id'].to_s[/\Abrowser-(\d+)\z/, 1].to_i }.reject(&:zero?)
    n = 1
    n += 1 while used.include?(n)
    n
  end

  def next_port(leases)
    used = leases.map { |l| l['port'].to_i }
    port = @base_port
    port += 1 while used.include?(port) || port_open?(port)
    port
  end

  def port_open?(port)
    TCPSocket.new('127.0.0.1', port.to_i).close
    true
  rescue Errno::ECONNREFUSED, Errno::EHOSTUNREACH, Errno::EINVAL
    false
  end

  def pids_for(user_data_dir)
    return [] unless user_data_dir && !user_data_dir.empty?

    `pgrep -f "user-data-dir=#{user_data_dir}" 2>/dev/null`.strip.split("\n").map(&:to_i).reject(&:zero?)
  end
end
