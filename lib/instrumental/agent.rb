require 'instrumental/rack/middleware'
require 'instrumental/version'
require 'logger'
require 'thread'
require 'socket'

# Sets up a connection to the collector.
#
#  Instrumental::Agent.new(API_KEY)
module Instrumental
  class Agent
    BACKOFF = 2.0
    MAX_RECONNECT_DELAY = 15
    COMMAND_BUFFER_SIZE = 500
    METRIC_BUFFER_SIZE = 100
    INITIAL_METRIC_BUFFER_RESOLUTION = 60
    INITIAL_FLUSH_INTERVAL = 60

    attr_accessor :host, :port
    attr_reader :connection, :enabled

    def self.logger=(l)
      @logger = l
    end

    def self.logger(force = false)
      @logger ||= Logger.new(File.open('/dev/null', 'a')) # append mode so it's forksafe
      # @logger = Logger.new(STDOUT)
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
      default_options = {
        :collector => 'instrumentalapp.com:8000',
        :enabled   => true,
        :test_mode => false,
      }
      options   = default_options.merge(options)
      collector = options[:collector].split(':')

      @api_key   = api_key
      @host      = collector[0]
      @port      = (collector[1] || 8000).to_i
      @enabled   = options[:enabled]
      @test_mode = options[:test_mode]
      @pid = Process.pid


      if @enabled
        @failures = 0
        start_connection_worker
        setup_cleanup_at_exit
      end
    end

    # Store a gauge for a metric, optionally at a specific time.
    #
    #  agent.gauge('load', 1.23)
    def gauge(metric, value, time = Time.now)
      if enabled? && valid?(metric, value, time) &&
          safe_buffer.gauge(metric, value, time.to_i)
        value
      else
        nil
      end
    rescue Exception => e
      report_exception(e)
      nil
    end

    # Increment a metric, optionally more than one or at a specific time.
    #
    #  agent.increment('users')
    def increment(metric, value = 1, time = Time.now)
      if enabled? && valid?(metric, value, time) &&
          safe_buffer.increment(metric, value, time.to_i)
        value
      else
        nil
      end
    rescue Exception => e
      report_exception(e)
      nil
    end

    def enabled?
      @enabled
    end

    def connected?
      @socket && !@socket.closed?
    end

    def logger
      self.class.logger
    end

    def store(*args)
      send_command(args.join(' '))
    end

    private

    def valid?(metric, value, time)
      if metric !~ /^([\d\w\-_]+\.)*[\d\w\-_]+$/i
        increment 'agent.invalid_metric'
        logger.warn "Invalid metric #{metric}"
        return false
      end
      if value.to_s !~ /^\d+(\.\d+)?$/
        increment 'agent.invalid_value'
        logger.warn "Invalid value #{value.inspect} for #{metric}"
        return false
      end
      true
    end

    def report_exception(e)
      logger.error "Exception occurred: #{e.message}"
      logger.error e.backtrace.join("\n")
    end

    def setup_new_worker_if_pid_changed
      if @pid != Process.pid
        logger.info "Detected fork"
        @pid = Process.pid
        @socket = nil
        start_connection_worker
      end
    end

    def safe_buffer
      setup_new_worker_if_pid_changed
      @buffer
    end

    def send_command(cmd, *args)
      if enabled?
        cmd = "%s %s\n" % [cmd, args.collect(&:to_s).join(" ")]
        if @queue.size < COMMAND_BUFFER_SIZE
          logger.debug "Queueing: #{cmd.chomp}"
          @queue << cmd
          cmd
        else
          logger.warn "Dropping command, queue full(#{@queue.size}): #{cmd.chomp}"
          nil
        end
      end
    end

    def test_connection
      # FIXME: Test connection state hack
      begin
        @socket.read_nonblock(1) # TODO: put data back?
      rescue Errno::EAGAIN
        # nop
      end
    end

    def start_connection_worker
      if enabled?
        disconnect
        @queue = Queue.new
        @buffer = MetricBuffer.new(INITIAL_METRIC_BUFFER_RESOLUTION, METRIC_BUFFER_SIZE, self)
        logger.info "Starting thread"
        @thread = Thread.new do
          loop do
            break if connection_worker
          end
        end
      end
    end

    def connection_worker
      command_and_args = nil
      logger.info "connecting to collector"
      @socket = TCPSocket.new(host, port)
      @failures = 0
      logger.info "connected to collector at #{host}:#{port}"
      @socket.puts "hello version #{Instrumental::VERSION} test_mode #{@test_mode}"
      @socket.puts "authenticate #{@api_key}"
      command, *args = @socket.gets.split(' ')
      options = {
        'resolution' => INITIAL_METRIC_BUFFER_RESOLUTION,
        'flush_interval' => INITIAL_FLUSH_INTERVAL,
      }
      case command
      when 'options'
        server_options = Hash[*args]
        logger.debug "Server supplied options: #{server_options.inspect}"
        options.merge!(server_options)
      else
      end
      @buffer.resolution = options['resolution'].to_i
      @flush_interval = options['flush_interval'].to_f
      @flusher = Thread.new { loop { sleep @flush_interval; @buffer.flush! } }
      loop do
        command_and_args = @queue.pop
        test_connection

        case command_and_args
        when 'exit'
          logger.info "exiting, #{@queue.size} commands remain"
          return true
        else
          logger.debug "Sending: #{command_and_args.chomp}"
          @socket.puts command_and_args
          command_and_args = nil
        end
      end
    rescue Exception => err
      logger.error err.to_s
      if command_and_args
        logger.debug "requeueing: #{command_and_args}"
        @queue << command_and_args 
      end
      @flusher.kill if @flusher.alive?
      disconnect
      @failures += 1
      delay = [(@failures - 1) ** BACKOFF, MAX_RECONNECT_DELAY].min
      logger.info "disconnected, reconnect in #{delay}..."
      sleep delay
      retry
    ensure
      @flusher.kill if @flusher.alive?
      disconnect
    end

    def setup_cleanup_at_exit
      at_exit do
        if @thread.alive?
          @buffer.flush! if @buffer
          if !@queue.empty?
            if @failures > 0
              logger.info "exit received but disconnected, dropping #{@queue.size} commands"
              @thread.kill
            else
              logger.info "exit received, #{@queue.size} commands to be sent"
              @queue << 'exit'
              @thread.join
            end
          end
        end
      end
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
