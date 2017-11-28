require 'capistrano'
require 'instrumental_agent'
require 'etc'

if Capistrano::Configuration.instance
  Capistrano::Configuration.instance.load do
    namespace :instrumental do
      namespace :util do
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
        start_at = exists?(:instrumental_deploy_start) ? instrumental_deploy_start : Time.now
        end_at = exists?(:instrumental_deploy_end) ? instrumental_deploy_end : start_at
        deploy_duration_in_seconds = end_at - start_at
        deployer = Etc.getlogin.chomp
        agent_options = { :synchronous => true }
        agent_options[:collector] = instrumental_host if exists?(:instrumental_host)
        agent = Instrumental::Agent.new(instrumental_key, agent_options)
        message = if exists?(:deploy_message)
          deploy_message
        else
          "#{deployer} deployed #{current_revision}"
        end
        agent.notice(message,
                     start_at,
                     deploy_duration_in_seconds)
        logger.info("Notified Instrumental of deployment")
      end
    end

    before "deploy", "instrumental:util:deploy_start"
    after  "deploy", "instrumental:util:deploy_end"
    before "deploy:migrations", "instrumental:util:deploy_start"
    after  "deploy:migrations", "instrumental:util:deploy_end"
    after  "instrumental:util:deploy_end", "instrumental:record_deploy_notice"
  end
end
