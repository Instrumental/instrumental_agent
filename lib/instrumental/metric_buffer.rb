module Instrumental
  class MetricBuffer
    attr_accessor :resolution, :delegate

    def initialize(resolution, max_size, delegate)
      @resolution = resolution
      @max_size = max_size
      @delegate = delegate
      @metrics = Hash.new(0)
    end

    def increment(metric, value, time)
      key = ['increment', metric, quantize_time(time)]
      if @metrics.size >= @max_size && !@metrics.include?(key)
        flush_one_metric
      end
      @metrics[key] += value
    end

    def gauge(metric, value, time)
      key = ['gauge', metric, quantize_time(time)]
      if @metrics.size >= @max_size && !@metrics.include?(key)
        flush_one_metric
      end
      @metrics[key] = value
    end

    def quantize_time(time)
      time - time % @resolution
    end

    def flush_one_metric
      keys = @metrics.keys
      key = keys[rand(keys.size)]
      flush_metric(key)
    end

    def flush_metric(key)
      value = @metrics.delete(key)
      type, metric, quantized_time = *key
      @delegate.store(type, metric, value, quantized_time)
    end

    def flush!
      @metrics.keys.each do |key|
        flush_metric(key)
      end
    end
  end
end
