defmodule Amezo.Secrets do
  @moduledoc """
  秘密鍵ファイル (trip / id / key / jump) の唯一の所有者。
  他版では読み書きが各所に散っていたが、ここではこのプロセスだけが作るので競合しない。
  鍵はファイルから読むか、無ければ作って保存する (Python 版 load_secret と同じ手順)。
  """
  use GenServer
  alias Amezo.{Config, Crypto, Util}

  @files %{
    trip: :trip_secret_file,
    id: :id_secret_file,
    key: :key_secret_file,
    jump: :jump_secret_file
  }

  def start_link(_), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)

  @doc "秘密鍵 (32バイト) を返す。保存できなければ nil。"
  def key(which), do: GenServer.call(__MODULE__, {:key, which})

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_call({:key, which}, _from, state) do
    case Map.fetch(state, which) do
      {:ok, k} ->
        {:reply, k, state}

      :error ->
        path = Config.app_path(apply(Config, Map.fetch!(@files, which), []))
        k = load_secret(path)
        {:reply, k, Map.put(state, which, k)}
    end
  end

  # ---------- Python 版 load_secret と同じ ----------
  def read_secret_key(path) do
    case Util.read_file_string(path) do
      {s, true} ->
        txt = Util.trim_space(s)

        if String.length(txt) == 64 and txt =~ ~r/\A[0-9a-fA-F]{64}\z/ do
          Crypto.hex_decode(txt)
        else
          nil
        end

      _ ->
        nil
    end
  end

  def load_secret(path) do
    case read_secret_key(path) do
      nil -> create_secret(path)
      k -> k
    end
  end

  defp create_secret(path) do
    key = Crypto.random_octets(32)
    data = Crypto.hex_encode(key) <> "\n"
    tmp = path <> ".tmp" <> to_string(:os.getpid())

    placed =
      if write_exclusive(tmp, data) do
        File.ln(tmp, path)
        File.rm(tmp)
        read_secret_key(path)
      end

    cond do
      not is_nil(placed) ->
        placed

      write_exclusive(path, data) ->
        read_secret_key(path)

      true ->
        k = wait_read(path, 20)

        cond do
          not is_nil(k) ->
            k

          true ->
            # 壊れた鍵ファイルは置き換える
            Util.write_file_string(path, data)
            Util.chmod_file(path, 0o600)
            read_secret_key(path)
        end
    end
  end

  defp wait_read(_path, 0), do: nil

  defp wait_read(path, n) do
    case read_secret_key(path) do
      nil ->
        Process.sleep(50)
        wait_read(path, n - 1)

      k ->
        k
    end
  end

  defp write_exclusive(path, data) do
    case File.open(path, [:write, :exclusive]) do
      {:ok, f} ->
        ok = IO.write(f, data) == :ok
        File.close(f)
        ok

      _ ->
        false
    end
  end
end
