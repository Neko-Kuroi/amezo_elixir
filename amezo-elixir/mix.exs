defmodule Amezo.MixProject do
  use Mix.Project

  def project do
    [
      app: :amezo,
      version: "1.0.0",
      elixir: "~> 1.14",
      start_permanent: Mix.env() == :prod,
      deps: [],
      releases: [
        amezo: [
          include_erts: true,
          include_executables_for: [:unix],
          steps: [:assemble]
        ]
      ]
    ]
  end

  def application do
    [
      mod: {Amezo.Application, []},
      extra_applications: [:crypto]
    ]
  end
end
