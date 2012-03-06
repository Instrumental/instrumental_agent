require 'rubygems'
require 'rubygems/command.rb'
require 'rubygems/dependency_installer.rb' 

begin
  if RUBY_VERSION < "1.9"
    require 'system_timer'
  end
rescue LoadError
  begin
    inst = Gem::DependencyInstaller.new
    inst.install "system_timer", "~> 1.2"
  rescue
    puts "Couldn't install system_timer gem, required on Ruby < 1.9"
    exit(1)
  end
end

f = File.open(File.join(File.dirname(__FILE__), "Rakefile"), "w")   # create dummy rakefile to indicate success
f.write("task :default\n")
f.close
