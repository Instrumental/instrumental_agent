$: << File.join(File.dirname(__FILE__), "..", "lib")

require 'instrumental_agent'
require 'test_server'

RSpec.configure do |config|

  config.before(:all) do
  end

  config.after(:all) do
  end

end


def parse_constant(constant)
  source, _, constant_name = constant.to_s.rpartition('::')

  [source.constantize, constant_name]
end

def with_constants(constants, &block)
  saved_constants = {}
  constants.each do |constant, val|
    source_object, const_name = parse_constant(constant)

    saved_constants[constant] = source_object.const_get(const_name)
    Kernel::silence_warnings { source_object.const_set(const_name, val) }
  end

  begin
    block.call
  ensure
    constants.each do |constant, val|
      source_object, const_name = parse_constant(constant)

      Kernel::silence_warnings { source_object.const_set(const_name, saved_constants[constant]) }
    end
  end
end
alias :with_constant :with_constants

class String
  # From Rails
  def constantize
    names = split('::')
    names.shift if names.empty? || names.first.empty?

    constant = Object
    names.each do |name|
      constant = constant.const_defined?(name) ? constant.const_get(name) : constant.const_missing(name)
    end
    constant
  end
end

module Kernel
  # File activesupport/lib/active_support/core_ext/kernel/reporting.rb, line 10
  def silence_warnings
    with_warnings(nil) { yield }
  end

  def with_warnings(flag)
    old_verbose, $VERBOSE = $VERBOSE, flag
    yield
  ensure
    $VERBOSE = old_verbose
  end
end