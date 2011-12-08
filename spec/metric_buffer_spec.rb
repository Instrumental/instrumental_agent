require 'spec_helper'

describe MetricBuffer do
  it "should send increments separately when they differ by the resolution" do
    delegate = mock('delegate')
    ta = MetricBuffer.new(60, 10, delegate)
    ta.increment('abc', 2, 2)
    ta.increment('abc', 3, 65)
    delegate.should_receive(:store).with('increment', 'abc', 2, 0)
    delegate.should_receive(:store).with('increment', 'abc', 3, 60)
    ta.flush!
  end

  it "should batch multiple increments into one by addition" do
    delegate = mock('delegate')
    ta = MetricBuffer.new(60, 10, delegate)
    ta.increment('abc', 2, 2)
    ta.increment('abc', 3, 11)
    delegate.should_receive(:store).with('increment', 'abc', 5, 0)
    ta.flush!
  end

  it "should send gauges separately when they differ by the resolution" do
    delegate = mock('delegate')
    ta = MetricBuffer.new(60, 10, delegate)
    ta.gauge('abc', 2, 2)
    ta.gauge('abc', 3, 65)
    delegate.should_receive(:store).with('gauge', 'abc', 2, 0)
    delegate.should_receive(:store).with('gauge', 'abc', 3, 60)
    ta.flush!
  end

  it "should batch multiple gauges into one by using the last value" do
    delegate = mock('delegate')
    ta = MetricBuffer.new(60, 10, delegate)
    ta.gauge('abc', 2, 2)
    ta.gauge('abc', 3, 11)
    delegate.should_receive(:store).with('gauge', 'abc', 3, 0)
    ta.flush!
  end

  it "should store metrics when size becomes larger than max_size" do
    delegate = mock('delegate')
    ta = MetricBuffer.new(60, 1, delegate)
    ta.gauge('abc', 2, 2)
    delegate.should_receive(:store).with('gauge', 'abc', 2, 0)
    ta.gauge('abc', 4, 131)
  end
end
