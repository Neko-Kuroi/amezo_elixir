defmodule Amezo.Counters do
  @moduledoc """
  揮発性カウンタの所有者。
  - 新規スレッドの全体制限 (global): メモリ保持 (再起動でリセットされる。他版の global.mem 相当)
  - 管理画面のログイン失敗 (admin_fail.mem): このプロセスだけが読み書きし、
    ファイル形式は他版と同一に保つ (flock の代わりにプロセスが直列化する)
  """
  use GenServer
  alias Amezo.{Config, Util}

  @admin_max_fails 5
  @admin_lock_sec 900
  @admin_fail_file "admin_fail.mem"

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  # ---------- 全体制限 ----------
  @doc "同じ接続元が window 秒以内に新規スレッドを立てていれば {:wait, 残り秒}、なければ記録して :ok。"
  def global_check_and_add(who, window) do
    GenServer.call(__MODULE__, {:global_check, who, window, Util.epoch_now()})
  end

  # ---------- 管理画面の失敗記録 ----------
  @doc "失敗が上限に達していれば true"
  def admin_blocked?(who), do: GenServer.call(__MODULE__, {:admin_blocked, who})

  @doc "認証結果を記録する (成功なら消す)。ファイルに書けなければ :error"
  def admin_record(who, ok), do: GenServer.call(__MODULE__, {:admin_record, who, ok})

  # ---------- 本体 ----------
  @impl true
  def init(_) do
    {:ok, %{global: %{}, admin_fails: load_admin_fails()}}
  end

  @impl true
  def handle_call({:global_check, who, window, now}, _from, state) do
    if window <= 0 do
      {:reply, :ok, state}
    else
      table =
        Map.filter(state.global, fn {_k, ts} -> now - ts < window end)

      case Map.fetch(table, who) do
        {:ok, ts} ->
          {:reply, {:wait, window - (now - ts)}, %{state | global: table}}

        :error ->
          {:reply, :ok, %{state | global: Map.put(table, who, now)}}
      end
    end
  end

  def handle_call({:admin_blocked, who}, _from, state) do
    fails = prune_admin(state.admin_fails, Util.epoch_now())
    blocked = match?(%{count: c} when c >= @admin_max_fails, Map.get(fails, who))
    {:reply, blocked, %{state | admin_fails: fails}}
  end

  def handle_call({:admin_record, who, ok}, _from, state) do
    now = Util.epoch_now()
    fails = prune_admin(state.admin_fails, now)

    fails =
      cond do
        ok -> Map.delete(fails, who)
        Map.has_key?(fails, who) -> Map.update!(fails, who, fn e -> %{e | count: e.count + 1, ts: now} end)
        true -> Map.put(fails, who, %{count: 1, ts: now})
      end

    case write_admin_fails(fails) do
      true -> {:reply, :ok, %{state | admin_fails: fails}}
      false -> {:reply, :error, %{state | admin_fails: fails}}
    end
  end

  defp prune_admin(fails, now) do
    Map.filter(fails, fn {_k, e} -> now - e.ts < @admin_lock_sec end)
  end

  defp load_admin_fails do
    now = Util.epoch_now()

    case Util.read_file_lines(Config.app_path(@admin_fail_file)) do
      {lines, true} ->
        Enum.reduce(lines, %{}, fn line, acc ->
          case Util.split_no_empty(line, " ") do
            [who, cnt, ts] ->
              if Util.all_digits?(cnt) and Util.all_digits?(ts) do
                ts_i = Util.safe_integer(ts, 0)

                if now - ts_i < @admin_lock_sec do
                  Map.put(acc, who, %{count: Util.safe_integer(cnt, 0), ts: ts_i})
                else
                  acc
                end
              else
                acc
              end

            _ ->
              acc
          end
        end)

      _ ->
        %{}
    end
  end

  defp write_admin_fails(fails) do
    content =
      Enum.map_join(fails, "", fn {who, e} -> "#{who} #{e.count} #{e.ts}\n" end)

    path = Config.app_path(@admin_fail_file)
    tmp = path <> ".tmp" <> to_string(:os.getpid())

    if Util.write_file_string(tmp, content) do
      Util.chmod_file(tmp, 0o600)

      case File.rename(tmp, path) do
        :ok -> true
        _ -> File.rm(tmp); false
      end
    else
      false
    end
  end
end
