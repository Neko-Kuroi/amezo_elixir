defmodule Amezo.Sys do
  @moduledoc """
  外部コマンド (gzip) の実行。他版と同じく gzip の作成・展開は外部コマンドに任せ、
  中身の照合は :crypto の SHA-256 で行う。
  """
  alias Amezo.{Crypto, Util}

  # コマンドの標準出力を集めて {出力, 終了ステータス} を返す。起動できなければ {"", -1}。
  def run_capture(exe_name, args) do
    case System.find_executable(exe_name) do
      nil ->
        {"", -1}

      exe ->
        port =
          Port.open({:spawn_executable, exe},
            [:binary, :exit_status, args: args]
          )

        collect(port, [])
    end
  end

  defp collect(port, acc) do
    receive do
      {^port, {:data, chunk}} -> collect(port, [chunk | acc])
      {^port, {:exit_status, status}} -> {acc |> Enum.reverse() |> IO.iodata_to_binary(), status}
    after
      120_000 -> {"", -1}
    end
  end

  # コマンドの標準出力を fun で畳み込む (大きい出力用)。{acc, ok}
  def run_fold(exe_name, args, acc, fun) do
    case System.find_executable(exe_name) do
      nil ->
        {acc, false}

      exe ->
        port = Port.open({:spawn_executable, exe}, [:binary, :exit_status, args: args])
        fold_loop(port, acc, fun)
    end
  end

  defp fold_loop(port, acc, fun) do
    receive do
      {^port, {:data, chunk}} -> fold_loop(port, fun.(acc, chunk), fun)
      {^port, {:exit_status, 0}} -> {acc, true}
      {^port, {:exit_status, _}} -> {acc, false}
    after
      120_000 -> {acc, false}
    end
  end

  # ---------- gzip ----------
  def gunzip_to_string(path) do
    case run_capture("gzip", ["-dc", path]) do
      {out, 0} -> {Util.utf8_decode(out), true}
      _ -> {"", false}
    end
  end

  def gzip_decompress_to_file(gz, out_path) do
    case File.open(out_path, [:write]) do
      {:ok, f} ->
        {_, ok} =
          run_fold("gzip", ["-dc", gz], f, fn file, chunk ->
            IO.binwrite(file, chunk)
            file
          end)

        File.close(f)
        ok

      _ ->
        false
    end
  end

  # (hex, 長さ, ok) を展開しながら数える
  def gzip_decompress_digest(gz) do
    init = {:crypto.hash_init(:sha256), 0}

    {{ctx, n}, ok} =
      run_fold("gzip", ["-dc", gz], init, fn {c, cnt}, chunk ->
        {:crypto.hash_update(c, chunk), cnt + byte_size(chunk)}
      end)

    if ok do
      {Crypto.hex_encode(:crypto.hash_final(ctx)), n, true}
    else
      {"", 0, false}
    end
  end

  def gzip_compress_file(plain, tmp) do
    case File.open(tmp, [:write]) do
      {:ok, f} ->
        {_, ok} =
          run_fold("gzip", ["-6", "-c", plain], f, fn file, chunk ->
            IO.binwrite(file, chunk)
            file
          end)

        File.close(f)
        ok

      _ ->
        false
    end
  end
end
