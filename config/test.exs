import Config

# Only in tests, remove the complexity from the password hashing algorithm
config :bcrypt_elixir, :log_rounds, 1

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :full_circle, FullCircle.Repo,
  username: "full_circle",
  password: "nyhlisted",
  hostname: "localhost",
  database: "full_circle_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: 10

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :full_circle, FullCircleWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "W2HCMbPzlsONP5vFXgcTF4zXTom+9ZtSqHeoJO4ctIQfCcp0fMPhSprTIbq2qqGi",
  server: false

# In test we don't send emails.
config :full_circle, FullCircle.Mailer, adapter: Swoosh.Adapters.Test

# Disable swoosh api client as it is only required for production adapters.
config :swoosh, :api_client, false

# Upload directory for company creation
config :full_circle, uploads_dir: System.tmp_dir!()

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime
