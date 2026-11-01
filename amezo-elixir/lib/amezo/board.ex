defmodule Amezo.Board do
  @moduledoc """
  板ごとの GenServer。このプロセスがその板の唯一の書き手になる (single-writer)。
  他版の flock による直列化の代わりに、書き込みは全部 run/2 経由でこのプロセスに集める。
  読み取りはプロセスを経由しない。
  """
  use GenServer

  # ---------- API ----------
  def ensure_started(folder) do
    if Amezo.Store.is_board(folder) do
      case Registry.lookup(Amezo.BoardRegistry, folder) do
        [{_pid, _}] ->
          :ok

        [] ->
          case DynamicSupervisor.start_child(
                 Amezo.BoardSupervisor,
                 {__MODULE__, folder}
               ) do
            {:ok, _} -> :ok
            {:error, {:already_started, _}} -> :ok
            _ -> :error
          end
      end
    else
      :error
    end
  end

  defp via(folder), do: {:via, Registry, {Amezo.BoardRegistry, folder}}

  @doc """
  fun を板プロセスの中で実行する。fun が Amezo.Exit.bail/1 で抜けたら {:bail, resp}、
  正常なら {:ok, 値}、例外なら {:raised, 例外} を返す。
  """
  def run(folder, fun, timeout \\ 60_000) do
    case ensure_started(folder) do
      :ok -> GenServer.call(via(folder), {:run, fun}, timeout)
      :error -> {:raised, %RuntimeError{message: "板プロセスを起動できません: #{folder}"}}
    end
  end

  @doc "板プロセスの状態を1つ読む (投稿間隔の確認など、軽い読み取り用)"
  def get_state(folder, key, default \\ nil) do
    case ensure_started(folder) do
      :ok -> GenServer.call(via(folder), {:get, key, default}, 10_000)
      :error -> default
    end
  end

  @doc "run/2 の中でだけ使える、板プロセスの状態へのアクセス"
  def state_get(key, default \\ nil) do
    case Process.get(:amezo_board_state) do
      %{} = s -> Map.get(s, key, default)
      _ -> default
    end
  end

  def state_put(key, value) do
    s = Process.get(:amezo_board_state, %{})
    Process.put(:amezo_board_state, Map.put(s, key, value))
  end

  def child_spec(folder) do
    %{id: {__MODULE__, folder}, start: {__MODULE__, :start_link, [folder]}, restart: :permanent}
  end

  def start_link(folder), do: GenServer.start_link(__MODULE__, folder, name: via(folder))

  # ---------- 本体 ----------
  @impl true
  def init(folder), do: {:ok, %{folder: folder}}

  @impl true
  def handle_call({:get, key, default}, _from, state) do
    {:reply, Map.get(state, key, default), state}
  end

  def handle_call({:run, fun}, _from, state) do
    Process.put(:amezo_board_state, state)

    result =
      try do
        {:ok, fun.()}
      rescue
        e -> {:raised, e}
      catch
        :exit, reason -> {:raised, %RuntimeError{message: "exit: #{inspect(reason)}"}}
        {:amezo_bail, resp} -> {:bail, resp}
      end

    new_state = Process.get(:amezo_board_state, state)
    Process.delete(:amezo_board_state)
    {:reply, result, new_state}
  end
end
