$: << File.join(File.dirname(__FILE__), "..", "lib")

require 'instrumental_agent'
require 'test_server'

include Instrumental

RSpec.configure do |config|

  config.before(:all) do
  end

  config.after(:all) do
  end

end
