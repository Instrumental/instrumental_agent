# Instrumental Agent

Measure your application in real time.

## Setup & Usage

Add the gem to your Gemfile.

```sh
gem 'instrumental_agent'
```

Visit [instrumentalapp.com](https://instrumentalapp.com) and create an account, then  initialize the agent with your API key, found in the Docs section.

```sh
I = Instrumental::Agent.new('YOUR_API_KEY', :enabled => Rails.env.production?)
```

You'll  probably want something like the above, only enabling the agent in production mode so you don't have development and production data writing to the same value. Or you can setup two projects, so that you can verify stats in one, and release them to production in another.

Now you can begin to use Instrumental to track your application.

```sh
I.gauge('load', 1.23)                # value at a point in time

I.increment('signups')               # increasing value, think "events"

I.time('query_time') do              # time a block of code
  post = Post.find(1)
end
I.time_ms('query_time_in_ms') do     # prefer milliseconds?
  post = Post.find(1)
end
```

**Note**: For your app's safety, the agent is meant to isolate your app from any problems our service might suffer. If it is unable to connect to the service, it will discard data after reaching a low memory threshold.

Want to track an event (like an application deploy, or downtime)? You can capture events that are instantaneous, or events that happen over a period of time.

```sh
I.notice('Jeffy deployed rev ef3d6a') # instantaneous event
I.notice('Testing socket buffer increase', 3.days.ago, 20.minutes) # an event with a duration
```

## Backfilling

Streaming data is better with a little historical context. Instrumental lets you  backfill data, allowing you to see deep into your project's past.

When backfilling, you may send tens of thousands of metrics per second, and the command buffer may start discarding data it isn't able to send fast enough. We provide a synchronous mode that will ensure every stat makes it to Instrumental before continuing on to the next.

**Warning**: You should only enable synchronous mode for backfilling data as any issues with the Instrumental service issues will cause this code to halt until it can reconnect.

```sh
I.synchronous = true # every command sends immediately
User.find_each do |user|
  I.increment('signups', 1, user.created_at)
end
```

## Server Stats

Want some general server stats (load, memory, etc.)? Check out the [instrumental_tools](https://github.com/fastestforward/instrumental_tools) gem.

```sh
gem install instrumental_tools
instrument_server
```

## Agent Control

Need to quickly disable the agent? set :enabled to false on initialization and you don't need to change any application code.


## Capistrano Integration

Add `require "instrumental/capistrano"` to your capistrano configuration and your deploys will be tracked by Instrumental.  Add the API token for the project you want to track to by setting the following Capistrano var:

```ruby
set :instrumental_key, "MY_API_KEY"
```

The following configuration will be added:

```ruby
before "deploy", "instrumental:util:deploy_start"
after  "deploy", "instrumental:util:deploy_end"
before "deploy:migrations", "instrumental:util:deploy_start"
after  "deploy:migrations", "instrumental:util:deploy_end"
after  "instrumental:util:deploy_end", "instrumental:record_deploy_notice"
```

The default message sent is "USER deployed COMMIT_HASH". If you need to customize it, set a capistrano variable named `deploy_message` to the value you'd prefer.

## Tracking metrics in Resque jobs (and Resque-like scenarios)

If you plan on tracking metrics in Resque jobs, you will need to explicitly cleanup after the agent when the jobs are finished.  You can accomplish this by adding `after_perform` and `on_failure` hooks to your Resque jobs.  See the Resque [hooks documentation](https://github.com/defunkt/resque/blob/master/docs/HOOKS.md) for more information.

You're required to do this because Resque calls `exit!` when a worker has finished processing, which bypasses Ruby's `at_exit` hooks.  The Instrumental Agent installs an `at_exit` hook to flush any pending metrics to the servers, but this hook is bypassed by the `exit!` call; any other code you rely that uses `exit!` should call `I.cleanup` to ensure any pending metrics are correctly sent to the server before exiting the process.

## Using with Ruby Enterprise Edition

Users of Ruby Enterprise Edition should plan on using version 0.9.5 of the Instrumental Agent or greater. Please see the [REE wiki page](https://github.com/fastestforward/instrumental_agent/wiki/Using-with-Ruby-Enterprise-Edition) for more information.


## Troubleshooting & Help

We are here to help. Email us at [support@instrumentalapp.com](mailto:support@instrumentalapp.com), or visit the [Instrumental Support](https://fastestforward.campfirenow.com/6b934) Campfire room.
