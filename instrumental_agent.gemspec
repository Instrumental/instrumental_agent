$:.push File.expand_path("../lib", __FILE__)
require "instrumental/version"

Gem::Specification.new do |s|
  s.name        = "instrumental_agent"
  s.version     = Instrumental::VERSION
  s.authors     = ["Elijah Miller", "Christopher Zelenak", "Kristopher Chambers", "Matthew Hassfurder"]
  s.email       = ["support@instrumentalapp.com"]
  s.homepage    = "http://github.com/fastestforward/instrumental_agent"
  s.summary     = %q{Agent for reporting data to instrumentalapp.com}
  s.description = %q{Track anything.}

  s.files         = `git ls-files`.split("\n")
  s.test_files    = `git ls-files -- {test,spec,features}/*`.split("\n")
  s.executables   = `git ls-files -- bin/*`.split("\n").map{ |f| File.basename(f) }
  s.require_paths = ["lib"]
  s.extensions    = 'ext/mkrf_conf.rb'
  s.add_development_dependency(%q<rake>, [">= 0"])
  s.add_development_dependency(%q<rspec>, ["~> 2.0"])
  s.add_development_dependency(%q<fuubar>, [">= 0"])
  if RUBY_VERSION >= "1.8.7"
    s.add_development_dependency(%q<guard>, [">= 0"])
    s.add_development_dependency(%q<guard-rspec>, [">= 0"])
    s.add_development_dependency(%q<growl>, [">= 0"])
    s.add_development_dependency(%q<rb-fsevent>, [">= 0"])
  end
end
