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
    MAX_BUFFER = 100

    attr_accessor :host, :port
    attr_reader :connection, :enabled

    def self.logger=(l)
      @logger = l
    end

    def self.logger
      @logger ||= Logger.new('/dev/null')
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

      if @enabled
        @failures = 0
        @queue = Queue.new
        start_connection_thread
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

    def enabled?
      @enabled
    end

    def connected?
      connection && connection.connected
    end

    def logger
      self.class.logger
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

    def send_command(cmd, *args)
      if enabled?
        cmd = "%s %s\n" % [cmd, args.collect(&:to_s).join(" ")]
        if @queue.size < MAX_BUFFER
          logger.debug "Queueing: #{cmd.chomp}"
          @queue << cmd
          cmd
        else
          logger.warn "Dropping command, queue full(#{@queue.size}): #{cmd.chomp}"
          nil
        end
      end
    end

    def test_server_connection
      # FIXME: Test connection state hack
      begin
        @socket.read_nonblock(1) # TODO: put data back?
      rescue Errno::EAGAIN
        # nop
      end
    end

    def start_connection_thread
      logger.info "Starting thread"
      @thread = Thread.new do
        begin
          @socket = TCPSocket.new(host, port)
          @failures = 0
          logger.info "connected to collector"
          @socket.puts "hello version #{Instrumental::VERSION} test_mode #{@test_mode}"
          @socket.puts "authenticate #{@api_key}"
          loop do
            command_and_args = @queue.pop
            begin
              test_server_connection
            rescue Exception => err
              @queue << command_and_args # connection dead, requeue
              raise err
            end

            if command_and_args == 'exit'
              logger.info "exiting, #{@queue.size} commands remain"
              @socket.flush
              Thread.exit
            else
              logger.debug "Sending: #{command_and_args.chomp}"
              @socket.puts command_and_args
            end
          end
        rescue Exception => err
          logger.error err.to_s
          # FIXME: not always a disconnect
          @failures += 1
          delay = [(@failures - 1) ** BACKOFF, MAX_RECONNECT_DELAY].min
          logger.info "disconnected, reconnect in #{delay}..."
          sleep delay
          retry
        end
      end
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
  end

end
