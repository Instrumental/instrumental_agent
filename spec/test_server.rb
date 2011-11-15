class TestServer
  attr_accessor :host, :port, :connect_count, :commands

  def initialize
    @connect_count = 0
    @connections = []
    @commands = []
    listen
  end

  def listen
    @port ||= 10001
    @server = TCPServer.new(port)
    Thread.new do
      begin
        # puts "listening"
        socket = @server.accept
        @connect_count += 1
        @connections << socket
        # puts "connection received"
        loop do
          command = socket.gets.strip
          # puts "got: #{command}"
          commands << command
        end
      rescue Exception => err
        unless @stopping
          # puts "EXCEPTION:", err unless @stopping
          retry
        end
      end
    end
    # puts "server up"
  rescue Exception => err
    # FIXME: doesn't seem to be detecting failures of listen
    puts "failed to get port"
    @port += 1
    retry
  end

  def host_and_port
    "#{host}:#{port}"
  end

  def stop
    @stopping = true
    disconnect_all
    @server.close # FIXME: necessary?
  end

  def disconnect_all
    @connections.each { |c| c.close rescue false }
  end
end
