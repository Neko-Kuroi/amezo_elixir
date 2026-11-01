defmodule Amezo.Application do
  @moduledoc """
  supervision tree の起点。モード (AMEZO_MODE=serve | cli) でサーバ側の子を足す。
  板ごとの GenServer は必要になった時点で DynamicSupervisor から起動する。
  """
  use Application

  @impl true
  def start(_type, _args) do
    Amezo.Config.load_config()

    if serve_mode?() do
      Amezo.Server.setup_directories()
    end

    base = [
      {Registry, keys: :unique, name: Amezo.BoardRegistry},
      Amezo.Secrets,
      Amezo.Counters,
      {DynamicSupervisor, name: Amezo.BoardSupervisor, strategy: :one_for_one},
      {DynamicSupervisor, name: Amezo.ConnSupervisor, strategy: :one_for_one}
    ]

    server =
      if serve_mode?() do
        [
          {Amezo.Server.Listener, port: Amezo.Server.port()},
          Amezo.Server.Boot
        ]
      else
        []
      end

    tunnel =
      if serve_mode?() and Amezo.Server.tunnel?() do
        [Amezo.Tunnel]
      else
        []
      end

    Supervisor.start_link(base ++ server ++ tunnel,
      strategy: :one_for_one,
      name: Amezo.Supervisor
    )
  end

  # 明示的に AMEZO_MODE=serve のときだけサーバを起動する (テストや CLI では起動しない)
  def serve_mode?, do: System.get_env("AMEZO_MODE") == "serve"
end
