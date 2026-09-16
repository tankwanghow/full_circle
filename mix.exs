defmodule FullCircle.MixProject do
  use Mix.Project

  def project do
    [
      app: :full_circle,
      version: "1.0.0",
      elixir: "~> 1.19",
      elixirc_paths: elixirc_paths(Mix.env()),
      # elixirc_options: [debug_info: Mix.env() == :dev],
      start_permanent: Mix.env() == :prod,
      listeners: [Phoenix.CodeReloader],
      aliases: aliases(),
      deps: deps()
    ]
  end

  # Configuration for the OTP application.
  #
  # Type `mix help compile.app` for more information.
  def application do
    [
      mod: {FullCircle.Application, []},
      extra_applications: [:logger, :runtime_tools, :inets, :ssl]
    ]
  end

  # Specifies which paths to compile per environment.
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Specifies your project dependencies.
  #
  # Type `mix help deps` for examples and options.
  defp deps do
    [
      {:bcrypt_elixir, "~> 3.0"},
      {:phoenix, "~> 1.8"},
      {:phoenix_ecto, "~> 4.5"},
      {:ecto_sql, "~> 3.14"},
      {:postgrex, ">= 0.0.0"},
      # ecto_sql 3.14 needs decimal ~> 3.0; number 1.0.5 still declares
      # decimal ~> 1.5 or ~> 2.0, so pin it ourselves. number only touches
      # new/from_float/compare/div/round/abs/to_string, all unchanged in 3.x.
      {:decimal, "~> 3.1", override: true},
      {:phoenix_html, "~> 4.1"},
      {:phoenix_live_reload, "~> 1.2", only: :dev},
      {:phoenix_live_view, "~> 1.2"},
      {:lazy_html, "~> 0.1", only: :test},
      {:esbuild, "~> 0.10", runtime: Mix.env() == :dev},
      {:tailwind, "~> 0.5", runtime: Mix.env() == :dev},
      heroicons_dep(),
      {:swoosh, "~> 1.5"},
      {:gen_smtp, "~> 1.2"},
      {:finch, "~> 0.13"},
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_poller, "~> 1.0"},
      # timex 3.7.13 (latest) declares gettext ~> 0.26; gettext 1.0 is that
      # release with no breaking changes, so override the stale requirement.
      {:gettext, "~> 1.0", override: true},
      {:jason, "~> 1.2"},
      {:dns_cluster, "~> 0.3.0"},
      {:bandit, "~> 1.5"},
      {:tzdata, "~> 1.1"},
      {:timex, "~> 3.0"},
      {:number, "~> 1.0"},
      {:countries, "~> 1.6"},
      {:nimble_csv, "~> 1.2"},
      {:xlsx_reader, "~> 0.8"},
      {:qr_code, "~> 3.2"},
      {:castore, "~> 1.0"},
      {:req, "~> 0.6"},
      {:tidewave, "~> 0.6", only: :dev}
    ]
  end

  # Aliases are shortcuts or tasks specific to the current project.
  # For example, to install project dependencies and perform other setup tasks, run:
  #
  #     $ mix setup
  #
  # See the documentation for `Mix` for more info on aliases.
  defp aliases do
    [
      setup: ["deps.get", "ecto.setup", "assets.setup", "assets.build"],
      "ecto.setup": ["ecto.create", "ecto.migrate", "run priv/repo/seeds.exs"],
      "ecto.reset": ["ecto.drop", "ecto.setup"],
      test: ["ecto.create --quiet", "ecto.migrate --quiet", "test"],
      "assets.setup": assets_setup_tasks(),
      "assets.build": ["tailwind full_circle", "esbuild full_circle"],
      "assets.deploy": [
        "tailwind full_circle --minify",
        "esbuild full_circle --minify",
        "phx.digest"
      ]
    ]
  end

  defp workspace_assets?,
    do: File.exists?(Path.expand("../shared_config/workspace_assets.ex", __DIR__))

  defp load_workspace_assets! do
    unless Code.ensure_loaded?(WorkspaceAssets) do
      Code.compile_file(Path.expand("../shared_config/workspace_assets.ex", __DIR__))
    end
  end

  defp heroicons_dep do
    if workspace_assets?() do
      load_workspace_assets!()
      WorkspaceAssets.heroicons_dep(__DIR__)
    else
      {:heroicons,
       github: "tailwindlabs/heroicons",
       tag: "v2.2.0",
       sparse: "optimized",
       app: false,
       compile: false,
       depth: 1}
    end
  end

  defp assets_setup_tasks do
    if workspace_assets?() do
      load_workspace_assets!()
      WorkspaceAssets.assets_setup_tasks(__DIR__)
    else
      ["tailwind.install --if-missing", "esbuild.install --if-missing"]
    end
  end
end
