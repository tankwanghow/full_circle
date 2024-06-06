defmodule FullCircle.QueryRepo do
  use Ecto.Repo,
    otp_app: :full_circle,
    adapter: Ecto.Adapters.Postgres,
    read_only: true
end
