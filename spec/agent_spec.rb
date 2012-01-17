require 'spec_helper'

def wait
  sleep 0.2 # FIXME: hack
end

describe Instrumental::Agent, "disabled" do
  before do
    Instrumental::Agent.logger.level = Logger::UNKNOWN
    @server = TestServer.new
    @agent = Instrumental::Agent.new('test_token', :collector => @server.host_and_port, :enabled => false)
  end

  after do
    @server.stop
  end

  it "should not connect to the server" do
    wait
    @server.connect_count.should == 0
  end

  it "should not connect to the server after receiving a metric" do
    wait
    @agent.gauge('disabled_test', 1)
    wait
    @server.connect_count.should == 0
  end

end

describe Instrumental::Agent, "enabled in test_mode" do
  before do
    @server = TestServer.new
    @agent = Instrumental::Agent.new('test_token', :collector => @server.host_and_port, :test_mode => true)
  end

  after do
    @server.stop
  end

  it "should connect to the server" do
    wait
    @server.connect_count.should == 1
  end

  it "should announce itself, and include version and test_mode flag" do
    wait
    @server.commands[0].should =~ /hello .*version .*test_mode true/
  end

  it "should authenticate using the token" do
    wait
    @server.commands[1].should == "authenticate test_token"
  end

  it "should report a gauge" do
    now = Time.now
    @agent.gauge('gauge_test', 123)
    wait
    @server.commands.last.should == "gauge gauge_test 123 #{now.to_i}"
  end

  it "should report a time as gauge and return the block result" do
    now = Time.now
    @agent.time("time_value_test") do
      sleep 0.1
      1 + 1
    end.should == 2
    wait
    @server.commands.last.should =~ /gauge time_value_test .* #{now.to_i}/
    time = @server.commands.last.scan(/gauge time_value_test (.*) #{now.to_i}/)[0][0].to_f
    time.should > 0.1
  end

  it "should allow a block used in .time to throw an exception and still be timed" do
    now = Time.now
    lambda {
      @agent.time("time_value_test") do
        sleep 0.1
        throw :an_exception
        sleep 1
      end
      }.should raise_error
    wait
    @server.commands.last.should =~ /gauge time_value_test .* #{now.to_i}/
    time = @server.commands.last.scan(/gauge time_value_test (.*) #{now.to_i}/)[0][0].to_f
    time.should > 0.1
  end

  it "should report a time as a millisecond gauge and return the block result" do
    now = Time.now
    @agent.time_ms("time_ms_test") do
      sleep 0.1
      1 + 1
    end.should == 2
    wait
    @server.commands.last.should =~ /gauge time_ms_test .* #{now.to_i}/
    time = @server.commands.last.scan(/gauge time_ms_test (.*) #{now.to_i}/)[0][0].to_f
    time.should > 100
  end

  it "should report an increment" do
    now = Time.now
    @agent.increment("increment_test")
    wait
    @server.commands.last.should == "increment increment_test 1 #{now.to_i}"
  end

  it "should send notices to the server" do
    tm = Time.now
    @agent.notice("Test note", tm)
    wait
    @server.commands.join("\n").should include("notice #{tm.to_i} 0 Test note")
  end
end

describe Instrumental::Agent, "enabled" do
  before do
    @server = TestServer.new
    @agent = Instrumental::Agent.new('test_token', :collector => @server.host_and_port, :synchronous => false)
  end

  after do
    @server.stop
  end

  it "should connect to the server" do
    wait
    @server.connect_count.should == 1
  end

  it "should announce itself, and include version" do
    wait
    @server.commands[0].should =~ /hello .*version /
  end

  it "should authenticate using the token" do
    wait
    @server.commands[1].should == "authenticate test_token"
  end

  it "should report a gauge" do
    now = Time.now
    @agent.gauge('gauge_test', 123)
    wait
    @server.commands.last.should == "gauge gauge_test 123 #{now.to_i}"
  end

  it "should report a time as gauge and return the block result" do
    now = Time.now
    @agent.time("time_value_test") do
      1 + 1
    end.should == 2
    wait
    @server.commands.last.should =~ /gauge time_value_test .* #{now.to_i}/
  end

  it "should return the value gauged" do
    now = Time.now
    @agent.gauge('gauge_test', 123).should == 123
    @agent.gauge('gauge_test', 989).should == 989
    wait
  end

  it "should report a gauge with a set time" do
    @agent.gauge('gauge_test', 123, 555)
    wait
    @server.commands.last.should == "gauge gauge_test 123 555"
  end

  it "should report an increment" do
    now = Time.now
    @agent.increment("increment_test")
    wait
    @server.commands.last.should == "increment increment_test 1 #{now.to_i}"
  end

  it "should return the value incremented by" do
    now = Time.now
    @agent.increment("increment_test").should == 1
    @agent.increment("increment_test", 5).should == 5
    wait
  end

  it "should report an increment a value" do
    now = Time.now
    @agent.increment("increment_test", 2)
    wait
    @server.commands.last.should == "increment increment_test 2 #{now.to_i}"
  end

  it "should report an increment with a set time" do
    @agent.increment('increment_test', 1, 555)
    wait
    @server.commands.last.should == "increment increment_test 1 555"
  end

  it "should discard data that overflows the buffer" do
    with_constants('Instrumental::Agent::MAX_BUFFER' => 3) do
      5.times do |i|
        @agent.increment('overflow_test', i + 1, 300)
      end
      wait
      @server.commands.should     include("increment overflow_test 1 300")
      @server.commands.should     include("increment overflow_test 2 300")
      @server.commands.should     include("increment overflow_test 3 300")
      @server.commands.should_not include("increment overflow_test 4 300")
      @server.commands.should_not include("increment overflow_test 5 300")
    end
  end

  it "should send all data in synchronous mode" do
    with_constants('Instrumental::Agent::MAX_BUFFER' => 3) do
      @agent.synchronous = true
      5.times do |i|
        @agent.increment('overflow_test', i + 1, 300)
      end
      wait # let the server receive the commands
      @server.commands.should include("increment overflow_test 1 300")
      @server.commands.should include("increment overflow_test 2 300")
      @server.commands.should include("increment overflow_test 3 300")
      @server.commands.should include("increment overflow_test 4 300")
      @server.commands.should include("increment overflow_test 5 300")
    end
  end

  it "should automatically reconnect when forked" do
    wait
    @agent.increment('fork_reconnect_test', 1, 2)
    fork do
      @agent.increment('fork_reconnect_test', 1, 3) # triggers reconnect
    end
    wait
    @agent.increment('fork_reconnect_test', 1, 4) # triggers reconnect
    wait
    @server.connect_count.should == 2
    @server.commands.should include("increment fork_reconnect_test 1 2")
    @server.commands.should include("increment fork_reconnect_test 1 3")
    @server.commands.should include("increment fork_reconnect_test 1 4")
  end

  it "should never let an exception reach the user" do
    @agent.stub!(:send_command).and_raise(Exception.new("Test Exception"))
    @agent.increment('throws_exception', 2).should be_nil
    wait
    @agent.gauge('throws_exception', 234).should be_nil
    wait
  end

  it "should let exceptions in time bubble up" do
    expect { @agent.time('za') { raise "fail" } }.to raise_error
  end

  it "should return nil if the user overflows the MAX_BUFFER" do
    thread = @agent.instance_variable_get(:@thread)
    thread.kill
    1.upto(Instrumental::Agent::MAX_BUFFER) do
      @agent.increment("test").should == 1
    end
    @agent.increment("test").should be_nil
  end

  it "should track invalid metrics" do
    @agent.logger.should_receive(:warn).with(/%%/)
    @agent.increment(' %% .!#@$%^&*', 1, 1)
    wait
    @server.commands.join("\n").should include("increment agent.invalid_metric")
  end

  it "should allow reasonable metric names" do
    @agent.increment('a')
    @agent.increment('a.b')
    @agent.increment('hello.world')
    @agent.increment('ThisIsATest.Of.The.Emergency.Broadcast.System.12345')
    wait
    @server.commands.join("\n").should_not include("increment agent.invalid_metric")
  end

  it "should track invalid values" do
    @agent.logger.should_receive(:warn).with(/hello.*testington/)
    @agent.increment('testington', 'hello')
    wait
    @server.commands.join("\n").should include("increment agent.invalid_value")
  end

  it "should allow reasonable values" do
    @agent.increment('a', -333.333)
    @agent.increment('a', -2.2)
    @agent.increment('a', -1)
    @agent.increment('a',  0)
    @agent.increment('a',  1)
    @agent.increment('a',  2.2)
    @agent.increment('a',  333.333)
    @agent.increment('a',  Float::EPSILON)
    wait
    @server.commands.join("\n").should_not include("increment agent.invalid_value")
  end

  it "should send notices to the server" do
    tm = Time.now
    @agent.notice("Test note", tm)
    wait
    @server.commands.join("\n").should include("notice #{tm.to_i} 0 Test note")
  end

  it "should prevent a note w/ newline characters from being sent to the server" do
    @agent.notice("Test note\n").should be_nil
    wait
    @server.commands.join("\n").should_not include("notice Test note")
  end
end

describe Instrumental::Agent, "connection problems" do
  after do
    @server.stop
  end

  it "should automatically reconnect on disconnect" do
    @server = TestServer.new
    @agent = Instrumental::Agent.new('test_token', :collector => @server.host_and_port, :synchronous => false)
    wait
    @server.disconnect_all
    @agent.increment('reconnect_test', 1, 1234) # triggers reconnect
    wait
    @server.connect_count.should == 2
    @server.commands.last.should == "increment reconnect_test 1 1234"
  end

  it "should buffer commands when server is down" do
    @server = TestServer.new(:listen => false)
    @agent = Instrumental::Agent.new('test_token', :collector => @server.host_and_port, :synchronous => false)
    wait
    @agent.increment('reconnect_test', 1, 1234)
    wait
    @agent.queue.pop(true).should == "increment reconnect_test 1 1234\n"
  end

  it "should buffer commands when server is not responsive" do
    @server = TestServer.new(:response => false)
    @agent = Instrumental::Agent.new('test_token', :collector => @server.host_and_port, :synchronous => false)
    wait
    @agent.increment('reconnect_test', 1, 1234)
    wait
    @agent.queue.pop(true).should == "increment reconnect_test 1 1234\n"
  end

  it "should buffer commands when authentication fails" do
    @server = TestServer.new(:authenticate => false)
    @agent = Instrumental::Agent.new('test_token', :collector => @server.host_and_port, :synchronous => false)
    wait
    @agent.increment('reconnect_test', 1, 1234)
    wait
    @agent.queue.pop(true).should == "increment reconnect_test 1 1234\n"
  end
end

describe Instrumental::Agent, "enabled with sync option" do
  before do
    @server = TestServer.new
    @agent = Instrumental::Agent.new('test_token', :collector => @server.host_and_port, :synchronous => true)
  end

  it "should send all data in synchronous mode" do
    with_constants('Instrumental::Agent::MAX_BUFFER' => 3) do
      5.times do |i|
        @agent.increment('overflow_test', i + 1, 300)
      end
      wait # let the server receive the commands
      @server.commands.should include("increment overflow_test 1 300")
      @server.commands.should include("increment overflow_test 2 300")
      @server.commands.should include("increment overflow_test 3 300")
      @server.commands.should include("increment overflow_test 4 300")
      @server.commands.should include("increment overflow_test 5 300")
    end
  end
end
