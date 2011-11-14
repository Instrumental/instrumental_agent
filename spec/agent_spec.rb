require 'spec_helper'

describe Instrumental::Agent, "disabled" do
  before do
    random_port = Time.now.to_i % rand(2000)
    base_port = 4000
    @port = base_port + random_port
    TestServer.start(@port)
  end

  after do
    TestServer.stop
  end

  subject { Instrumental::Agent.new('test_token', :collector => "127.0.0.1:#{@port}", :enabled => false) }

  it 'should not connect to the server' do
    subject.gauge('gauge_test', 123)
    EM.next do
      TestServer.last.should be_nil
    end
  end

end

describe Instrumental::Agent do
  before do
    random_port = Time.now.to_i % rand(2000)
    base_port = 4000
    @port = base_port + random_port
    TestServer.start(@port)
  end

  after do
    TestServer.stop
  end

  subject { Instrumental::Agent.new('test_token', :collector => "127.0.0.1:#{@port}") }

  it 'should announce itself including version' do
    subject.gauge('gauge_test', 123)
    EM.next do
      TestServer.buffer.first.should match(/hello.*version/)
    end
  end

  it 'should authenticate using the token' do
    subject.gauge('gauge_test', 123)
    EM.next do
      TestServer.buffer[1].should == "authenticate test_token"
    end
  end

  it 'should report a gauge to the collector' do
    now = Time.now
    subject.gauge('gauge_test', 123)
    EM.next do
      TestServer.last_message.should == "gauge gauge_test 123 #{now.to_i}"
    end
  end

  it 'should report a gauge to the collector with a set time' do
    subject.gauge('gauge_test', 123, 555)
    EM.next do
      TestServer.last_message.should == 'gauge gauge_test 123 555'
    end
  end

  it 'should allow closing the connection to the server' do
    ts = Time.now.to_i
    1.upto(100) do |i|
      subject.gauge('flush_test', 100, ts + i)
    end
    subject.close
    TestServer.last_message.should == "gauge flush_test 100 #{ts + 100}"
    subject.should_not be_connected
  end

  it "should automatically reconnect" do
    EM.next do
      subject.gauge('gauge_test', 123, 555)
    end
    EM.next do
      subject.connection.close_connection(false)
    end
    EM.next do
      subject.gauge('gauge_test', 444, 555)
    end
    EM.next do
      TestServer.last_message.should == 'gauge gauge_test 444 555'
    end
  end

end
