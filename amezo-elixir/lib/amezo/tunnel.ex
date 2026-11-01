defmodule Amezo.Tunnel do
  @moduledoc """
  cloudflared クイックトンネルを Port で包む GenServer (supervision 配下)。
  Go 版 server.go の startTunnel / ensureCloudflared 相当。
  """
  use GenServer
  alias Amezo.{Config, Sys, Util}

  # ---------- 公開 API (CLI の --setup-tunnel からも使う) ----------
  def cloudflared_on_path, do: System.find_executable("cloudflared") || ""
  def cloudflared_local_path, do: Config.app_path("cloudflared")

  # ダウンロードしたファイルが本物の実行ファイルらしいか確かめる
  # (HTTP エラーの本文をバイナリと誤認しないため。Lisp 版の既知の問題への対策)
  def cloudflared_valid?(path) do
    case File.open(path, [:read, :binary]) do
      {:ok, f} ->
        {sz, _} = Util.file_size(path)

        magic =
          case IO.binread(f, 4) do
            data when is_binary(data) -> data
            _ -> ""
          end

        File.close(f)
        sz >= 1_000_000 and magic == <<0x7F, "ELF">>

      _ ->
        false
    end
  end

  def download_cloudflared(dest) do
    arch = :erlang.system_info(:system_architecture) |> to_string()

    asset =
      if String.contains?(arch, "aarch64") or String.contains?(arch, "arm") do
        "cloudflared-linux-arm64"
      else
        "cloudflared-linux-amd64"
      end

    url = "https://github.com/cloudflare/cloudflared/releases/latest/download/" <> asset
    IO.puts("cloudflared をダウンロード中... (#{url})")

    case Sys.run_capture("curl", ["-fsSL", url, "-o", dest]) do
      {_, 0} ->
        Util.chmod_file(dest, 0o755)

        if cloudflared_valid?(dest) do
          true
        else
          File.rm(dest)
          false
        end

      _ ->
        File.rm(dest)
        false
    end
  end

  # Python 版と同じく、PATH に無ければアプリフォルダへダウンロードする
  def ensure_cloudflared do
    on_path = cloudflared_on_path()

    if on_path != "" do
      on_path
    else
      local = cloudflared_local_path()

      cond do
        Util.file_regular?(local) and cloudflared_valid?(local) ->
          local

        true ->
          # 壊れた (エラーページ等) ファイルは消して取り直す
          if Util.file_regular?(local), do: File.rm(local)
          if download_cloudflared(local), do: local, else: ""
      end
    end
  end

  # cloudflared の出力行から公開URLを取り出す。無ければ ""。
  # エラー行に出る api.trycloudflare.com は公開URLではないので拾わない
  def extract_tunnel_url(line) do
    cond do
      String.contains?(line, "failed") ->
        ""

      true ->
        case :binary.match(line, "https://") do
          :nomatch ->
            ""

          {start, 8} ->
            rest = binary_part(line, start, byte_size(line) - start)
            marker = ".trycloudflare.com"

            case :binary.match(rest, marker) do
              :nomatch ->
                ""

              {m, _} ->
                host = binary_part(rest, 8, m - 8)
                if host == "api", do: "", else: binary_part(rest, 0, m + byte_size(marker))
            end
        end
    end
  end

  def setup_tunnel_command do
    bin = ensure_cloudflared()

    if bin == "" do
      IO.puts(:stderr, "❌ cloudflared を用意できませんでした。")
      1
    else
      case Sys.run_capture(bin, ["--version"]) do
        {out, 0} ->
          line = out |> Util.trim_space() |> String.split("\n") |> hd()
          IO.puts("✅ cloudflared の用意ができました: #{line} (#{bin})")
          0

        _ ->
          IO.puts(:stderr, "❌ cloudflared を実行できませんでした。")
          1
      end
    end
  end

  # ---------- GenServer ----------
  def start_link(_arg) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @impl true
  def init(_) do
    {:ok, %{port: nil, os_pid: nil, buf: "", url_found: false}, {:continue, :start}}
  end

  @impl true
  def handle_continue(:start, state) do
    IO.puts("☁️ Cloudflare Tunnel をセットアップしています...")
    bin = ensure_cloudflared()

    if bin == "" do
      IO.puts("❌ cloudflared を用意できませんでした (ダウンロードに失敗)。トンネルは張れません。")
      {:noreply, state}
    else
      port = Amezo.Server.port()

      p =
        Port.open({:spawn_executable, bin}, [
          :binary,
          :exit_status,
          :stderr_to_stdout,
          args: ["tunnel", "--url", "http://127.0.0.1:#{port}"]
        ])

      os_pid = Port.info(p)[:os_pid]
      IO.puts("⏳ トンネルの公開URLを取得しています...")
      Process.send_after(self(), :url_timeout, 20_000)
      {:noreply, %{state | port: p, os_pid: os_pid}}
    end
  end

  @impl true
  def handle_info({port, {:data, chunk}}, %{port: port} = state) do
    data = state.buf <> chunk
    parts = String.split(data, "\n")
    {lines, [rest]} = Enum.split(parts, -1)

    state =
      Enum.reduce(lines, %{state | buf: rest}, fn line, st ->
        IO.puts(line)

        if not st.url_found do
          case extract_tunnel_url(line) do
            "" ->
              st

            u ->
              IO.puts("\n🎉: #{u}/\n")
              %{st | url_found: true}
          end
        else
          st
        end
      end)

    {:noreply, state}
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    IO.puts("cloudflared が終了しました (status #{status})")
    {:noreply, %{state | port: nil}}
  end

  def handle_info(:url_timeout, state) do
    if not state.url_found and not is_nil(state.port) do
      IO.puts("❌ 公開URLの取得に失敗しました。トンネルプロセスの出力を確認してください。")
    end

    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    if state.os_pid do
      Sys.run_capture("kill", ["-TERM", Integer.to_string(state.os_pid)])
    end

    :ok
  end
end
