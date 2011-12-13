# Instrumental Agent

Instrument anything.

## Setup & Usage

Add the gem to your Gemfile.

```sh
gem 'instrumental_agent'
```

Visit instrumentalapp.com[instrumentalapp.com] and create an account,
then  initialize the agent with your API key, found in the Docs section.
You'll  probably want something like this, only enabling the agent in
production mode so you don't pollute your data.

```sh
I = Instrumental::Agent.new('YOUR_API_KEY', :test_mode => !Rails.env.production?)
```

You may want to setup two projects, so that you can verify stats in one,
and release them to production in another.

Now you can begin to use Instrumental to track your application.

```sh
I.gauge('load', 1.23)
I.increment('signups')
```

Streaming data is better with a little historical context. Instrumental
lets you  backfill data, allowing you to see deep into your project's
past.

```sh
I.synchronous = true # disables command buffering
User.find_each do |user|
  I.increment('signups', 1, user.created_at)
end
```

Want some general server stats (load, memory, etc.)? Check out the instrumental_tools gem.

```sh
gem install instrumental_tools
instrument_server
```

Running under Rails? You can also give our experimental Rack middleware 
a shot by initializing it with:

```sh
Instrumental::Middleware.boot
```

Need to quickly disable the agent? set :enabled to false on initialization and you don't need to change any application code.

## Troubleshooting & Help

We are here to help, please email us at [support@instrumentalapp.com](mailto:support@instrumentalapp.com).
