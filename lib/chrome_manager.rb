# frozen_string_literal: true

require 'json'
require 'fileutils'
require 'socket'
require 'time'
require 'open3'
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

  def lease(connect_agent_browser: false)
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
      connect_agent_browser!(lease) if connect_agent_browser
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

      # Release means cleanup both layers: agent-browser session/daemon state and
      # the real Chrome process. Close agent-browser first; if it is connected to
      # the leased Chrome this may close it, and BgChrome#stop below is the
      # fallback that kills any remaining profile-bound Chrome processes.
      Open3.capture2e('agent-browser', '--session', lease.fetch('session'), 'close')

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

  def check(id)
    lease = find_lease(id)
    cdp_url = agent_browser_cdp_url(lease)
    actual_port = cdp_url&.match(%r{127\.0\.0\.1:(\d+)})&.[](1)&.to_i
    {
      'id' => lease['id'],
      'session' => lease['session'],
      'expectedPort' => lease['port'],
      'cdpUrl' => cdp_url,
      'connected' => actual_port == lease['port'].to_i
    }
  end

  def connect_agent_browser(id)
    lease = find_lease(id)
    connect_agent_browser!(lease)
    check(id)
  end

  private

  def with_lock
    FileUtils.mkdir_p(@home)
    File.open(File.join(@home, 'lock'), File::RDWR | File::CREAT, 0o600) do |f|
      f.flock(File::LOCK_EX)
      yield
    end
  end

  def find_lease(id)
    leases = load_leases
    lease = leases.find { |l| l['id'] == id || l['session'] == id || l['port'].to_s == id.to_s }
    raise "unknown lease: #{id}" unless lease

    lease
  end

  def connect_agent_browser!(lease)
    # Safety rule:
    # Always reset the agent-browser session before connecting it to the leased
    # Chrome. The same session name may be left over from a previous run, may be
    # connected to agent-browser's own auto-launched Chrome, or may point at a
    # stale/random CDP port after the agent-browser daemon restarted. A direct
    # `connect <leased-port>` can report success without replacing that state
    # reliably, so close first, then connect and verify.
    Open3.capture2e('agent-browser', '--session', lease.fetch('session'), 'close')
    sleep 1

    3.times do |attempt|
      sleep 0.5 if attempt.positive?
      ok = system('agent-browser', '--session', lease.fetch('session'), 'connect', lease.fetch('port').to_s, out: $stderr, err: $stderr)
      raise 'agent-browser connect failed' unless ok

      verified_url = agent_browser_cdp_url(lease)
      verified_port = verified_url&.match(%r{127\.0\.0\.1:(\d+)})&.[](1)&.to_i
      return if verified_port == lease.fetch('port').to_i

      Open3.capture2e('agent-browser', '--session', lease.fetch('session'), 'close')
      sleep 1
    end

    raise "agent-browser connect did not stick for session #{lease.fetch('session')}"
  end

  def agent_browser_cdp_url(lease)
    out, st = Open3.capture2e('agent-browser', '--session', lease.fetch('session'), 'get', 'cdp-url')
    st.success? ? out.strip : nil
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
