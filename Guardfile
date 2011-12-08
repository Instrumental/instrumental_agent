guard 'rspec', :version => 2, :cli => '--format Fuubar' do
  watch(%r{^spec/.+_spec\.rb$})
  watch(%r{^lib/(.+)\.rb$})     { |m| "spec/#{File.basename(m[1])}_spec.rb" }
  watch(%r{spec/(spec_helper|test_server).rb})  { "spec/" }
end
