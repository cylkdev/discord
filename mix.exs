defmodule Discord.MixProject do
  use Mix.Project

  def project do
    [
      app: :discord,
      version: "0.1.0",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger],
      mod: {Discord.Application, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:gun, "~> 2.2"},
      {:bandit, "~> 1.6"},
      {:plug, "~> 1.16"},
      {:req, "~> 0.5"},
      {:flared, git: "https://github.com/cylkdev/flared.git", branch: "main"}
    ]
  end
end
