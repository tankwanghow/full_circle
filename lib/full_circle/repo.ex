defmodule FullCircle.Repo do
  use Ecto.Repo,
    otp_app: :full_circle,
    adapter: Ecto.Adapters.Postgres
end
