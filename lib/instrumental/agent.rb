require 'instrumental/rack/middleware'
require 'instrumental/version'
require 'eventmachine'
require 'logger'

# Sets up a connection to the collector.
#
#  Instrumental::Agent.new(API_KEY)
module Instrumental
  class Agent
    attr_accessor :host, :port
    attr_reader :connection, :enabled, :attempt_reconnect
    
    def self.start_reactor
      unless EM.reactor_running?
        logger.debug 'Starting EventMachine reactor'
        Thread.new { EM.run }
      end
    end

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

    module ServerConnection
      BACKOFF = 2
      MAX_RECONNECT_DELAY = 5
      MAX_BUFFER = 10

      attr_accessor :agent
      attr_reader :connected, :failures, :buffer

      def initialize(agent, api_key)
        @agent = agent
        @buffer = []
        @api_key = api_key
      end

      def logger
        agent.logger
      end

      def connection_completed
        logger.info "connected to collector"
        @connected = true
        @failures = 0
        send_data("hello version #{Instrumental::VERSION}\n")
        send_data("authenticate #{@api_key}\n") if @api_key
        dropped = @buffer.dup
        @buffer = []
        dropped.each do |msg|
          send_data(msg)
        end
      end

      def receive_data(data)
        logger.debug "Received: #{data.chomp}"
      end

      def send_data(data)
        if @connected
          super
        else
          if @buffer.size < MAX_BUFFER
            @buffer << data
          end
        end
      end

      def unbind
        @connected = false
        if agent.attempt_reconnect
          @failures = @failures.to_i + 1
          delay = [@failures ** BACKOFF / 10.to_f, MAX_RECONNECT_DELAY].min
          logger.info "disconnected, reconnect in #{delay}..."
          EM::Timer.new(delay) do
            reconnect(agent.host, agent.port)
          end
        end
      end

    end

    # Sets up a connection to the collector.
    #
    #  Instrumental::Agent.new(API_KEY)
    #  Instrumental::Agent.new(API_KEY, :collector => 'hostname:port')
    def initialize(api_key, options = {})
      default_options = { :start_reactor => true, :enabled => true }
      options = default_options.merge(options)
      @api_key = api_key
      @attempt_reconnect = true
      if options[:collector]
        @host, @port = options[:collector].split(':')
        @port = (@port || 8000).to_i
      else
        @host = 'instrumentalapp.com'
        @port = 8000
      end

      @enabled = options[:enabled]

      if @enabled
        if options[:start_reactor]
          self.class.start_reactor
        end

        EM.next_tick do
          @connection = EM.connect host, port, ServerConnection, self, api_key
        end
      end
    end

    # Store a gauge for a metric, optionally at a specific time.
    #
    #  agent.gauge('load', 1.23)
    def gauge(metric, value, time = Time.now)
      if valid?(metric, value, time)
        send_command("gauge", metric, value, time.to_i)
      end
    end

    # Increment a metric, optionally more than one or at a specific time.
    #
    #  agent.increment('users')
    def increment(metric, value = 1, time = Time.now)
      valid?(metric, value, time)
      send_command("increment", metric, value, time.to_i)
    end

    # Block until all metrics are sent to the server and then close
    # This WILL block your calling thread
    #
    # agent.close
    def close
      if connection
        @attempt_reconnect = false
        EM.next_tick do
          connection.close_connection(true)
        end
        sleep(0.1) while connected?
      end
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

    def send_command(cmd, *args)
      if enabled?
        cmd = "%s %s\n" % [cmd, args.collect(&:to_s).join(" ")]
        logger.debug "Sending: #{cmd.chomp}"
        EM.next_tick do
          connection.send_data(cmd)
        end
      end
    end


  end
end
