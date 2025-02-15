# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :number,
  currency: [
    unit: "",
    precision: 2,
    delimiter: ",",
    separator: ".",
    # "£30.00"
    format: "%u%n",
    # "(£30.00)"
    negative_format: "(%u%n)"
  ]

config :number,
  percentage: [
    delimiter: ",",
    separator: ".",
    precision: 2
  ]

config :full_circle, FullCircle.Repo,
  migration_timestamps: [type: :timestamptz],
  migration_primary_key: [name: :id, type: :binary_id]

config :full_circle,
  ecto_repos: [FullCircle.Repo]

# Configures the endpoint
config :full_circle, FullCircleWeb.Endpoint,
  adapter: Bandit.PhoenixAdapter,
  url: [host: "localhost"],
  render_errors: [
    formats: [html: FullCircleWeb.ErrorHTML, json: FullCircleWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: FullCircle.PubSub,
  live_view: [signing_salt: "D+1ROsdl"]

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.24.2",
  full_circle: [
    args: ~w(js/app.js js/tri_autocomplete.js js/take_photo_human.js
             js/face_id.js js/qr_attend.js
        --chunk-names=chunks/[name]-[hash] --splitting
        --bundle --target=es2017 --format=esm
        --outdir=../priv/static/assets --external:/fonts/* --external:/images/*
        --external:/sounds/* --external:/models/*),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => Path.expand("../deps", __DIR__)}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "3.4.17",
  full_circle: [
    args: ~w(
      --config=tailwind.config.js
      --input=css/app.css
      --output=../priv/static/assets/app.css
    ),
    cd: Path.expand("../assets", __DIR__)
  ]

# Configures Elixir's Logger
config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

config :tzdata, :autoupdate, :disabled

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
