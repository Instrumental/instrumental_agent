if RUBY_VERSION < "1.9" && RUBY_PLATFORM != "java"
  timeout_lib = nil
  ["SystemTimer", "system_timer"].each do |lib|
    begin
      unless timeout_lib
        gem lib
        require "system_timer"
        timeout_lib  = SystemTimer
      end
    rescue Exception => e
    end
  end
  if !timeout_lib
    puts <<-EOMSG
WARNING:: You do not currently have system_timer installed.
It is strongly advised that you install this gem when using
instrumental_agent with Ruby 1.8.x.  You can install it in
your Gemfile via:
gem 'system_timer'
or manually via:
gem install system_timer
    EOMSG
    require 'timeout'
    InstrumentalTimeout = Timeout
  else
    InstrumentalTimeout = timeout_lib
  end
else
  require 'timeout'
  InstrumentalTimeout = Timeout
end
