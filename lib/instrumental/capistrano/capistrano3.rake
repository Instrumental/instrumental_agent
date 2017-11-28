require "etc"
require "instrumental_agent"

namespace :load do
  task :defaults do
    set :instrumental_hooks, true
    set :instrumental_key,   nil
    set :deployer,           Etc.getlogin.chomp
  end
end

namespace :deploy do
  before :starting, :check_instrumental_hooks do
    invoke "instrumental:util:add_hooks" if fetch(:instrumental_hooks)
  end
end

namespace :instrumental do
  namespace :util do
    desc "add instrumental hooks to deploy"
    task :add_hooks do
      before "deploy", "instrumental:util:deploy_start"
      after  "deploy", "instrumental:util:deploy_end"
      after  "instrumental:util:deploy_end", "instrumental:record_deploy_notice"
    end

    desc "marker for beginning of deploy"
    task :deploy_start do
      set :instrumental_deploy_start, Time.now
    end

    desc "marker for end of deploy"
    task :deploy_end do
      set :instrumental_deploy_end, Time.now
    end
  end

  desc "send a notice to instrumental about the deploy"
  task :record_deploy_notice do
    start_at                   = fetch(:instrumental_deploy_start, Time.now)
    end_at                     = fetch(:instrumental_deploy_end, start_at)
    deploy_duration_in_seconds = end_at - start_at
    deployer                   = fetch(:deployer)
    agent_options              = { :synchronous => true }
    agent_options[:collector]  = instrumental_host if fetch(:instrumental_host)
    message                    = fetch(:deploy_message, "#{deployer} deployed #{fetch(:current_revision)}".strip)

    if fetch(:instrumental_key)
      agent = Instrumental::Agent.new(fetch(:instrumental_key), agent_options)
      agent.notice(message,
                   start_at,
                   deploy_duration_in_seconds)
      puts "Notified Instrumental of deployment"
    end
  end
end
