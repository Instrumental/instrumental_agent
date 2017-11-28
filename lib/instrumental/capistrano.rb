if Gem::Specification.find_by_name("capistrano").version >= Gem::Version.new("3.0.0")
  load File.expand_path("../capistrano/capistrano3.rake", __FILE__)
else
  require_relative "capistrano/capistrano2"
end
