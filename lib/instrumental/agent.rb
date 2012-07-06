require 'instrumental/rack/middleware'
require 'instrumental/version'
require 'logger'
require 'thread'
require 'socket'

if RUBY_VERSION < "1.9" && RUBY_PLATFORM != "java"
  timeout_lib = nil
  ["SystemTimer", "system_timer"].each do |lib|
    begin
      unless timeout_lib
        gem lib
        require "system_timer"
        timeout_lib  = SystemTimer
      end
    rescue Exception => e
    end
  end
  if !timeout_lib
    puts <<-EOMSG
WARNING:: You do not currently have system_timer installed.
It is strongly advised that you install this gem when using
instrumental_agent with Ruby 1.8.x.  You can install it in
your Gemfile via:
gem 'system_timer'
or manually via:
gem install system_timer
    EOMSG
    require 'timeout'
    InstrumentalTimeout = Timeout
  else
    InstrumentalTimeout = timeout_lib
  end
else
  require 'timeout'
  InstrumentalTimeout = Timeout
end


# Sets up a connection to the collector.
#
#  Instrumental::Agent.new(API_KEY)
module Instrumental
  class Agent
    BACKOFF = 2.0
    MAX_RECONNECT_DELAY = 15
    MAX_BUFFER = 5000
    REPLY_TIMEOUT = 10
    CONNECT_TIMEOUT = 20
    EXIT_FLUSH_TIMEOUT = 5

    attr_accessor :host, :port, :synchronous, :queue
    attr_reader :connection, :enabled

    def self.logger=(l)
      @logger = l
    end

    def self.logger
      if !@logger
        @logger = Logger.new(STDERR)
        @logger.level = Logger::WARN
      end
      @logger
    end

    def self.all
      @agents ||= []
    end

    def self.new(*args)
      inst = super
      all << inst
      inst
    end

    # Sets up a connection to the collector.
    #
    #  Instrumental::Agent.new(API_KEY)
    #  Instrumental::Agent.new(API_KEY, :collector => 'hostname:port')
    def initialize(api_key, options = {})
      # symbolize options keys
      options.replace(
        options.inject({}) { |m, (k, v)| m[(k.to_sym rescue k) || k] = v; m }
      )

      # defaults
      # host:        instrumentalapp.com
      # port:        8000
      # enabled:     true
      # synchronous: false
      @api_key         = api_key
      @host, @port     = options[:collector].to_s.split(':')
      @host          ||= 'instrumentalapp.com'
      @port            = (@port || 8000).to_i
      @enabled         = options.has_key?(:enabled) ? !!options[:enabled] : true
      @synchronous     = !!options[:synchronous]
      @pid             = Process.pid
      @allow_reconnect = true

      setup_cleanup_at_exit if @enabled
    end

    # Store a gauge for a metric, optionally at a specific time.
    #
    #  agent.gauge('load', 1.23)
    def gauge(metric, value, time = Time.now)
      if valid?(metric, value, time) &&
          send_command("gauge", metric, value, time.to_i)
        value
      else
        nil
      end
    rescue Exception => e
      report_exception(e)
      nil
    end

    # Store the duration of a block in a metric. multiplier can be used
    # to scale the duration to desired unit or change the duration in
    # some meaningful way.
    #
    #  agent.time('response_time') do
    #    # potentially slow stuff
    #  end
    #
    #  agent.time('response_time_in_ms', 1000) do
    #    # potentially slow stuff
    #  end
    #
    #  ids = [1, 2, 3]
    #  agent.time('find_time_per_post', 1 / ids.size.to_f) do
    #    Post.find(ids)
    #  end
    def time(metric, multiplier = 1)
      start = Time.now
      begin
        result = yield
      ensure
        finish = Time.now
        duration = finish - start
        gauge(metric, duration * multiplier, start)
      end
      result
    end

    # Calls time and changes durations into milliseconds.
    def time_ms(metric, &block)
      time(metric, 1000, &block)
    end

    # Increment a metric, optionally more than one or at a specific time.
    #
    #  agent.increment('users')
    def increment(metric, value = 1, time = Time.now)
      if valid?(metric, value, time) &&
          send_command("increment", metric, value, time.to_i)
        value
      else
        nil
      end
    rescue Exception => e
      report_exception(e)
      nil
    end

    # Send a notice to the server (deploys, downtime, etc.)
    #
    #  agent.notice('A notice')
    def notice(note, time = Time.now, duration = 0)
      if valid_note?(note)
        send_command("notice", time.to_i, duration.to_i, note)
        note
      else
        nil
      end
    rescue Exception => e
      report_exception(e)
      nil
    end

    # Synchronously flush all pending metrics out to the server
    # By default will not try to reconnect to the server if a
    # connection failure happens during the flush, though you
    # may optionally override this behavior by passing true.
    #
    #  agent.flush
    def flush(allow_reconnect = false)
      queue_message('flush', {
        :synchronous => true,
        :allow_reconnect => allow_reconnect
      }) if running?
    end

    def enabled?
      @enabled
    end

    def connected?
      @socket && !@socket.closed?
    end

    def logger=(logger)
      @logger = logger
    end

    def logger
      @logger ||= self.class.logger
    end

    # Stopping the agent will immediately stop all communication
    # to Instrumental.  If you call this and submit another metric,
    # the agent will start again.
    #
    # Calling stop will cause all metrics waiting to be sent to be
    # discarded.  Don't call it unless you are expecting this behavior.
    #
    # agent.stop
    #
    def stop
      disconnect
      if @thread
        @thread.kill
        @thread = nil
      end
    end

    # Called when a process is exiting to give it some extra time to
    # push events to the service. An at_exit handler is automatically
    # registered for this method, but can be called manually in cases
    # where at_exit is bypassed like Resque workers.
    def cleanup
      if running?
        logger.info "Cleaning up agent, queue size: #{@queue.size}, thread running: #{@thread.alive?}"
        @allow_reconnect = false
        if @queue.size > 0
          queue_message('exit')
          begin
            with_timeout(EXIT_FLUSH_TIMEOUT) { @thread.join }
          rescue Timeout::Error
            if @queue.size > 0
              logger.error "Timed out working agent thread on exit, dropping #{@queue.size} metrics"
            else
              logger.error "Timed out Instrumental Agent, exiting"
            end
          end
        end
      end
    end

    private

    def with_timeout(time, &block)
      InstrumentalTimeout.timeout(time) { yield }
    end

    def valid_note?(note)
      note !~ /[\n\r]/
    end

    def valid?(metric, value, time)
      valid_metric = metric =~ /^([\d\w\-_]+\.)*[\d\w\-_]+$/i
      valid_value  = value.to_s =~ /^-?\d+(\.\d+)?(e-\d+)?$/

      return true if valid_metric && valid_value

      report_invalid_metric(metric) unless valid_metric
      report_invalid_value(metric, value) unless valid_value
      false
    end

    def report_invalid_metric(metric)
      increment "agent.invalid_metric"
      logger.warn "Invalid metric #{metric}"
    end

    def report_invalid_value(metric, value)
      increment "agent.invalid_value"
      logger.warn "Invalid value #{value.inspect} for #{metric}"
    end

    def report_exception(e)
      logger.error "Exception occurred: #{e.message}"
      logger.error e.backtrace.join("\n")
    end

    def send_command(cmd, *args)
      if enabled?
        start_connection_worker if !running?

        cmd = "%s %s\n" % [cmd, args.collect { |a| a.to_s }.join(" ")]
        if @queue.size < MAX_BUFFER
          logger.debug "Queueing: #{cmd.chomp}"
          queue_message(cmd, { :synchronous => @synchronous })
        else
          logger.warn "Dropping command, queue full(#{@queue.size}): #{cmd.chomp}"
          nil
        end
      end
    end

    def queue_message(message, options = {})
      if @enabled
        options ||= {}
        if options[:allow_reconnect].nil?
          options[:allow_reconnect] = @allow_reconnect
        end
        synchronous = options.delete(:synchronous)
        if synchronous
          options[:sync_resource] ||= ConditionVariable.new
          @sync_mutex.synchronize {
            @queue << [message, options]
            options[:sync_resource].wait(@sync_mutex)
          }
        else
          @queue << [message, options]
        end
      end
      message
    end

    def test_connection
      # FIXME: Test connection state hack
      begin
        @socket.read_nonblock(1) # TODO: put data back?
      rescue Errno::EAGAIN
        # noop
      end
    end

    def start_connection_worker
      if enabled?
        disconnect
        @pid = Process.pid
        @queue = Queue.new
        @sync_mutex = Mutex.new
        @failures = 0
        logger.info "Starting thread"
        @thread = Thread.new do
          run_worker_loop
        end
      end
    end

    def send_with_reply_timeout(message)
      @socket.puts message
      with_timeout(REPLY_TIMEOUT) do
        response = @socket.gets
        if response.to_s.chomp != "ok"
          raise "Bad Response #{response.inspect} to #{message.inspect}"
        end
      end
    end

    def run_worker_loop
      command_and_args = nil
      command_options = nil
      logger.info "connecting to collector"
      @socket = with_timeout(CONNECT_TIMEOUT) { TCPSocket.new(host, port) }
      logger.info "connected to collector at #{host}:#{port}"
      send_with_reply_timeout "hello version #{Instrumental::VERSION} hostname #{Socket.gethostname}"
      send_with_reply_timeout "authenticate #{@api_key}"
      @failures = 0
      loop do
        command_and_args, command_options = @queue.pop
        sync_resource = command_options && command_options[:sync_resource]
        test_connection
        case command_and_args
        when 'exit'
          logger.info "Exiting, #{@queue.size} commands remain"
          return true
        when 'flush'
          release_resource = true
        else
          logger.debug "Sending: #{command_and_args.chomp}"
          @socket.puts command_and_args
        end
        command_and_args = nil
        command_options = nil
        if sync_resource
          @sync_mutex.synchronize do
            sync_resource.signal
          end
        end
      end
    rescue Exception => err
      logger.debug err.to_s
      logger.debug err.backtrace.join("\n")
      if @allow_reconnect == false ||
        (command_options && command_options[:allow_reconnect] == false)
        logger.error "Not trying to reconnect"
        return
      end
      if command_and_args
        logger.debug "requeueing: #{command_and_args}"
        @queue << command_and_args
      end
      disconnect
      @failures += 1
      delay = [(@failures - 1) ** BACKOFF, MAX_RECONNECT_DELAY].min
      logger.error "disconnected, #{@failures} failures in a row, reconnect in #{delay}..."
      sleep delay
      retry
    ensure
      disconnect
    end

    def setup_cleanup_at_exit
      at_exit do
        cleanup
      end
    end

    def running?
      !@thread.nil? && @pid == Process.pid
    end

    def disconnect
      if connected?
        logger.info "Disconnecting..."
        @socket.flush
        @socket.close
      end
      @socket = nil
    end

  end

end
