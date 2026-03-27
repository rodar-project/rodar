defmodule Rodar.MixProject do
  use Mix.Project

  def project do
    [
      app: :rodar,
      version: "1.4.1",
      elixir: "~> 1.16",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      package: package(),
      deps: deps(),
      description: "A BPMN engine for Elixir",

      # Docs
      name: "Rodar Workflow",
      source_url: "https://github.com/rodar-project/rodar",
      homepage_url: "https://rodar-project.github.io/rodar/",
      test_coverage: [tool: ExCoveralls],
      dialyzer: [plt_add_apps: [:mix, :ex_unit]],
      docs: docs()
    ]
  end

  defp package do
    [
      name: "rodar",
      files: ["lib", "mix.exs", "README*", "LICENSE*", "CHANGELOG.md", "usage-rules.md"],
      maintainers: ["Rodrigo Couto"],
      licenses: ["Apache-2.0"],
      links: %{"GitHub" => "https://github.com/rodar-project/rodar"}
    ]
  end

  def cli do
    [preferred_envs: [coveralls: :test]]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {Rodar.Application, []}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.34", only: [:dev, :test], runtime: false},
      {:excoveralls, "~> 0.18", only: [:dev, :test], runtime: false},
      {:jason, "~> 1.4"},
      {:erlsom, "~> 1.5"},
      {:rodar_feel, path: "../feel"},
      {:telemetry, "~> 1.2"},
      {:rodar_release, "~> 1.2", only: :dev, runtime: false}
    ]
  end

  defp docs do
    [
      main: "readme",
      extras: [
        "README.md",
        "DEVELOPER.md",
        "CONTRIBUTING.md",
        "CODE_OF_CONDUCT.md",
        "CHANGELOG.md",
        "guides/getting_started.md",
        "guides/process_lifecycle.md",
        "guides/events.md",
        "guides/gateways.md",
        "guides/expressions.md",
        "guides/task_handlers.md",
        "guides/hooks.md",
        "guides/persistence.md",
        "guides/versioning.md",
        "guides/observability.md",
        "guides/cli.md",
        "guides/workflow.md"
      ],
      groups_for_extras: [
        Guides: ~r/guides\/.*/
      ],
      groups_for_modules: [
        Core: [
          Rodar,
          Rodar.Token,
          Rodar.Context,
          Rodar.Process,
          Rodar.Registry,
          Rodar.Migration,
          Rodar.Lane
        ],
        Events: [
          Rodar.Event.Start,
          Rodar.Event.Start.Trigger,
          Rodar.Event.End,
          Rodar.Event.Intermediate,
          Rodar.Event.Intermediate.Throw,
          Rodar.Event.Intermediate.Catch,
          Rodar.Event.Boundary,
          Rodar.Event.Bus,
          Rodar.Event.Timer,
          Rodar.Compensation
        ],
        Gateways: [
          Rodar.Gateway.Exclusive,
          Rodar.Gateway.Parallel,
          Rodar.Gateway.Inclusive,
          Rodar.Gateway.Complex,
          Rodar.Gateway.Exclusive.Event
        ],
        Tasks: [
          Rodar.Activity.Task.Script,
          Rodar.Activity.Task.User,
          Rodar.Activity.Task.Service,
          Rodar.Activity.Task.Send,
          Rodar.Activity.Task.Receive,
          Rodar.Activity.Task.Manual
        ],
        Extensions: [Rodar.TaskHandler, Rodar.TaskRegistry, Rodar.Hooks],
        Observability: [
          Rodar.Telemetry,
          Rodar.Telemetry.LogHandler,
          Rodar.Observability
        ],
        Persistence: [
          Rodar.Persistence,
          Rodar.Persistence.Serializer,
          Rodar.Persistence.Adapter.ETS
        ],
        Internals: [
          Rodar.Engine.Diagram,
          Rodar.Engine.Diagram.Export,
          Rodar.Expression,
          Rodar.Expression.Sandbox,
          Rodar.Expression.Feel,
          Rodar.Validation,
          Rodar.Collaboration,
          Rodar.SequenceFlow
        ]
      ]
    ]
  end
end
