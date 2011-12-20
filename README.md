# Instrumental Agent

Instrument anything.

## Setup & Usage

Add the gem to your Gemfile.

```sh
gem 'instrumental_agent'
```

Visit [instrumentalapp.com](instrumentalapp.com) and create an account,
then  initialize the agent with your API key, found in the Docs section.

```sh
I = Instrumental::Agent.new('YOUR_API_KEY', :enabled => Rails.env.production?)
```

You'll  probably want something like the above, only enabling the agent
in production mode so you don't have development and produciton data
writing to the same value. Or you can setup two projects, so that you
can verify stats in one, and release them to production in another.

Now you can begin to use Instrumental to track your application.

```sh
I.gauge('load', 1.23)  # value at a point in time
I.increment('signups') # increasing value, think "events"
```

**Note**: For your app's safety, the agent is meant to isolate your app
from any problems our service might suffer. If it is unable to connect
to the service, it will discard data after reaching a low memory
threshold.

## Backfilling

Streaming data is better with a little historical context. Instrumental
lets you  backfill data, allowing you to see deep into your project's
past.

When backfilling, you may send tens of thousands of metrics per
second, and the command buffer may start discarding data it isn't able
to send fast enough. We provide a synchronous mode that will ensure
every stat makes it to Instrumental before continuing on to the next.

**Warning**: You should only enable synchronous mode for backfilling
data as any issues with the Instrumental service issues will cause this
code to halt until it can reconnect.

```sh
I.synchronous = true # every command sends immediately
User.find_each do |user|
  I.increment('signups', 1, user.created_at)
end
```

Want to track an event (like an application deploy, or downtime)? You can capture events that
are instantaneous, or events that happen over a period of time.

```sh
I.notice('Jeffy deployed rev ef3d6a') # instantaneous event
I.notice('Testing socket buffer increase', 3.days.ago, 20.minutes) # an event with a duration
```

## Server stats

Want some general server stats (load, memory, etc.)? Check out the
[instrumental_tools](https://github.com/fastestforward/instrumental_tools)
gem.

```sh
gem install instrumental_tools
instrument_server
```

## Rack middleware

Running under Rails? You can also give our experimental Rack middleware 
a shot by initializing it with:

```sh
Instrumental::Middleware.boot
```

Need to quickly disable the agent? set :enabled to false on
initialization and you don't need to change any application code.

## Troubleshooting & Help

We are here to help, please email us at
[support@instrumentalapp.com](mailto:support@instrumentalapp.com).
