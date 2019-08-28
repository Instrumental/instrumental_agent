require 'instrumental/version'
require 'instrumental/system_timer'
require 'logger'
require 'openssl' rescue nil
require 'resolv'
require 'thread'
require 'socket'
require 'metrician'


module Instrumental
  class Agent
    BACKOFF                            = 2.0
    CONNECT_TIMEOUT                    = 20
    EXIT_FLUSH_TIMEOUT                 = 5
    HOSTNAME                           = Socket.gethostbyname(Socket.gethostname).first rescue Socket.gethostname
    MAX_BUFFER                         = 5000
    MAX_RECONNECT_DELAY                = 15
    REPLY_TIMEOUT                      = 10
    RESOLUTION_FAILURES_BEFORE_WAITING = 3
    RESOLUTION_WAIT                    = 30
    RESOLVE_TIMEOUT                    = 1


    attr_accessor :host, :port, :synchronous, :queue, :dns_resolutions, :last_connect_at
    attr_reader :connection, :enabled, :secure

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
      # host:        collector.instrumentalapp.com
      # port:        8001
      # enabled:     true
      # synchronous: false
      # secure:      true
      # verify:      true
      @api_key         = api_key
      @host, @port     = options[:collector].to_s.split(':')
      @host          ||= 'collector.instrumentalapp.com'
      requested_secure = options[:secure] == true
      desired_secure   = options[:secure].nil? ? allows_secure? : !!options[:secure]
      if !allows_secure? && desired_secure
        logger.warn "Cannot connect to Instrumental via encrypted transport, SSL not available"
        if requested_secure
          options[:enabled] = false
          logger.error "You requested secure protocol to connect to Instrumental, but it is not available on this system (OpenSSL is not defined). Connecting to Instrumental has been disabled."
        end
        desired_secure = false
      end
      @secure          = desired_secure
      @verify_cert     = options[:verify_cert].nil? ? true : !!options[:verify_cert]
      default_port     = @secure ? 8001 : 8000
      @port            = (@port || default_port).to_i
      @enabled         = options.has_key?(:enabled) ? !!options[:enabled] : true
      @synchronous     = !!options[:synchronous]
      @pid             = Process.pid
      @allow_reconnect = true
      @dns_resolutions = 0
      @last_connect_at = 0
      @metrician       = options[:metrician].nil? ? true : !!options[:metrician]
      @start_worker_mutex = Mutex.new
      @queue = Queue.new

      setup_cleanup_at_exit if @enabled

      if @metrician
        Metrician.activate(self)
      end
    end

    # Store a gauge for a metric, optionally at a specific time.
    #
    #  agent.gauge('load', 1.23)
    def gauge(metric, value, time = Time.now, count = 1)
      if valid?(metric, value, time, count) &&
          send_command("gauge", metric, value, time.to_i, count.to_i)
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
    def increment(metric, value = 1, time = Time.now, count = 1)
      if valid?(metric, value, time, count) &&
          send_command("increment", metric, value, time.to_i, count.to_i)
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
      @logger || self.class.logger
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
      if @queue
        @queue.clear
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

    def valid?(metric, value, time, count)
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
      logger.error "Exception of type #{e.class} occurred:\n#{e.message}\n#{e.backtrace.join("\n")}"
    end

    def ipv4_address_for_host(host, port, moment_to_connect = Time.now.to_i)
      self.dns_resolutions  = dns_resolutions + 1
      time_since_last_connect = moment_to_connect - last_connect_at
      if dns_resolutions < RESOLUTION_FAILURES_BEFORE_WAITING || time_since_last_connect >= RESOLUTION_WAIT
        self.last_connect_at = moment_to_connect
        with_timeout(RESOLVE_TIMEOUT) do
          address  = Resolv.getaddresses(host).select { |address| address =~ Resolv::IPv4::Regex }.first
          self.dns_resolutions = 0
          address
        end
      end
    rescue Exception => e
      logger.warn "Couldn't resolve address for #{host}:#{port}"
      report_exception(e)
      nil
    end

    def send_command(cmd, *args)
      cmd = "%s %s\n" % [cmd, args.collect { |a| a.to_s }.join(" ")]
      if enabled?

        start_connection_worker
        if @queue && @queue.size < MAX_BUFFER
          @queue_full_warning = false
          logger.debug "Queueing: #{cmd.chomp}"
          queue_message(cmd, { :synchronous => @synchronous })
        else
          if !@queue_full_warning
            @queue_full_warning = true
            logger.warn "Queue full(#{@queue.size}), dropping commands..."
          end
          logger.debug "Dropping command, queue full(#{@queue.size}): #{cmd.chomp}"
          nil
        end
      else
        logger.debug cmd.strip
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

    def wait_exceptions
      classes = [Errno::EAGAIN]
      if defined?(IO::EAGAINWaitReadable)
        classes << IO::EAGAINWaitReadable
      end
      if defined?(IO::EWOULDBLOCKWaitReadable)
        classes << IO::EWOULDBLOCKWaitReadable
      end
      if defined?(IO::WaitReadable)
        classes << IO::WaitReadable
      end
      classes
    end


    def test_connection
      begin
        @socket.read_nonblock(1)
        @failures = 0
      rescue *wait_exceptions
        # no-op
      end
    end

    def start_connection_worker
      # NOTE: We need a mutex around both `running?` and thread creation,
      # otherwise we could create two threads.
      # Return early and queue the message if another thread is
      # starting the worker.
      return if !@start_worker_mutex.try_lock
      begin
        return if running?
        return unless enabled?
        disconnect
        address = ipv4_address_for_host(@host, @port)
        if address
          @pid = Process.pid
          @sync_mutex = Mutex.new
          @failures = 0
          @sockaddr_in = Socket.pack_sockaddr_in(@port, address)
          logger.info "Starting thread"
          @thread = Thread.new do
            run_worker_loop
          end
        end
      ensure
        @start_worker_mutex.unlock
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

    def open_socket(sockaddr_in, secure, verify_cert)
      sock = Socket.new(Socket::PF_INET, Socket::SOCK_STREAM, 0)
      sock.connect(sockaddr_in)
      if secure
        context = OpenSSL::SSL::SSLContext.new
        if verify_cert
          context.set_params(:verify_mode => OpenSSL::SSL::VERIFY_PEER | OpenSSL::SSL::VERIFY_FAIL_IF_NO_PEER_CERT)
        else
          context.set_params(:verify_mode => OpenSSL::SSL::VERIFY_NONE)
        end
        ssl_socket = OpenSSL::SSL::SSLSocket.new(sock, context)
        ssl_socket.sync_close = true
        ssl_socket.connect
        sock = ssl_socket
      end
      sock
    end

    def run_worker_loop
      @failures = 0
      begin
      logger.info "connecting to collector"
      command_and_args = nil
      command_options = nil
        with_timeout(CONNECT_TIMEOUT) do
          @socket = open_socket(@sockaddr_in, @secure, @verify_cert)
        end
        logger.info "connected to collector at #{host}:#{port}"
        hello_options = {
          "version" => "ruby/instrumental_agent/#{VERSION}",
          "hostname" => HOSTNAME,
          "pid" => Process.pid,
          "runtime" => "#{defined?(RUBY_ENGINE) ? RUBY_ENGINE : "ruby"}/#{RUBY_VERSION}p#{RUBY_PATCHLEVEL}",
          "platform" => RUBY_PLATFORM
        }.to_a.flatten.map { |v| v.to_s.gsub(/\s+/, "_") }.join(" ")

        send_with_reply_timeout "hello #{hello_options}"
        send_with_reply_timeout "authenticate #{@api_key}"

        loop do
          command_and_args, command_options = @queue.pop
          if command_and_args
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
        end
      rescue Exception => err
        allow_reconnect = @allow_reconnect
        case err
        when EOFError
        # nop
        when Errno::ECONNREFUSED, Errno::EHOSTUNREACH, Errno::EADDRINUSE, Timeout::Error, OpenSSL::SSL::SSLError
          # If the connection has been refused by Instrumental
          # or we cannot reach the server
          # or the connection state of this socket is in a race
          # or SSL is not functioning properly for some reason
          logger.error "unable to connect to Instrumental, hanging up with #{@queue.size} messages remaining"
          logger.debug "Exception: #{err.inspect}\n#{err.backtrace.join("\n")}"
          allow_reconnect = false
        else
          report_exception(err)
        end
        if allow_reconnect == false ||
           (command_options && command_options[:allow_reconnect] == false)
          logger.info "Not trying to reconnect"
          @failures = 0
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
    end

    def setup_cleanup_at_exit
      at_exit do
        cleanup
      end
    end

    def running?
      !@thread.nil? && @pid == Process.pid && @thread.alive?
    end

    def flush_socket(socket)
      socket.flush
    rescue Exception => e
      logger.error "Error flushing socket, #{e.message}"
    end

    def disconnect
      if connected?
        logger.info "Disconnecting..."
        begin
          with_timeout(EXIT_FLUSH_TIMEOUT) do
            flush_socket(@socket)
          end
        rescue Timeout::Error
          logger.info "Timed out flushing socket..."
        end
        @socket.close
      end
    rescue Exception => e
      logger.error "Error closing socket, #{e.message}"
    ensure
      @socket = nil
    end

    def allows_secure?
      defined?(OpenSSL)
    end
  end
end
