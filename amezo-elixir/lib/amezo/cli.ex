defmodule Amezo.CLI do
  @moduledoc """
  release の eval から呼ばれるコマンドライン入口。
  引数は環境変数 AMEZO_ARGV (US 区切り) で run.sh / archive.sh から受け取る。
  """
  alias Amezo.{Archive, Config, Crypto, Tunnel, Util}

  def argv do
    case System.get_env("AMEZO_ARGV") do
      nil -> []
      s -> String.split(s, <<31>>, trim: true)
    end
  end

  def main do
    Config.load_config()
    System.halt(dispatch(argv()))
  end

  defp dispatch(["--make-hash", pw]) do
    IO.puts(Crypto.make_hash(pw))
    0
  end

  defp dispatch(["--make-hash"]) do
    IO.puts(:stderr, "Usage: run.sh --make-hash PASSWORD")
    1
  end

  defp dispatch(["--make-delpass" | rest]) do
    pw = List.first(rest) || ""

    if pw == "" do
      IO.puts(:stderr, "❌ 合言葉が空です。")
      1
    else
      Util.write_file_string(Config.app_path("delpass.txt"), Crypto.make_hash(pw) <> "\n")
      Util.chmod_file(Config.app_path("delpass.txt"), 0o600)
      IO.puts("✅ delpass.txt を作りました。管理画面は /admin.cgi です。")
      0
    end
  end

  defp dispatch(["--setup-tunnel"]) do
    Tunnel.setup_tunnel_command()
  end

  defp dispatch(["archive" | rest]), do: archive_cli(rest)
  defp dispatch(["--archive" | rest]), do: archive_cli(rest)

  defp dispatch([]) do
    0
  end

  defp dispatch([other | _]) do
    IO.puts(:stderr, "不明な引数: #{other}")
    1
  end

  defp archive_cli(args) do
    Application.ensure_all_started(:amezo)
    {code, out, err} = Archive.main(args)
    if out != "", do: IO.write(out)
    if err != "", do: IO.write(:stderr, err)
    code
  end

  @doc """
  archive.sh が稼働中ノードへ rpc で呼ぶ入口。
  出力は rpc 経由で呼び出し側の標準出力に届く。終了コードは最終行の
  センチネル (AMEZO_ARCHIVE_EXIT:N) で archive.sh に伝える。
  """
  def archive_rpc(args) do
    {code, out, err} = Archive.main(args)
    IO.write(out <> err)
    IO.puts("AMEZO_ARCHIVE_EXIT:#{code}")
    :ok
  end
end
