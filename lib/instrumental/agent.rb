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
    MAX_BUFFER = 5000

    attr_accessor :host, :port, :synchronous
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
        @queue = Queue.new
        start_connection_worker
        setup_cleanup_at_exit
      end
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
    # agent.notice('A notice')
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

    private

    def valid_note?(note)
      note !~ /[\n\r]/
    end

    def valid?(metric, value, time)
      valid_metric = metric =~ /^([\d\w\-_]+\.)*[\d\w\-_]+$/i
      valid_value  = value.to_s =~ /^-?\d+(\.\d+)?$/

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
        if @pid != Process.pid
          logger.info "Detected fork"
          @pid = Process.pid
          @socket = nil
          @queue = Queue.new
          start_connection_worker
        end

        cmd = "%s %s\n" % [cmd, args.collect(&:to_s).join(" ")]
        if @queue.size < MAX_BUFFER
          logger.debug "Queueing: #{cmd.chomp}"
          @main_thread = Thread.current if @synchronous
          @queue << cmd
          Thread.stop if @synchronous
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
        @main_thread.run if @synchronous
      end
    rescue Exception => err
      logger.error err.to_s
      if command_and_args
        logger.debug "requeueing: #{command_and_args}"
        @queue << command_and_args 
      end
      disconnect
      @failures += 1
      delay = [(@failures - 1) ** BACKOFF, MAX_RECONNECT_DELAY].min
      logger.info "disconnected, reconnect in #{delay}..."
      sleep delay
      retry
    ensure
      disconnect
    end

    def setup_cleanup_at_exit
      at_exit do
        if !@queue.empty? && @thread.alive?
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
