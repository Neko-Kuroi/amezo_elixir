defmodule Amezo.Server do
  @moduledoc """
  HTTP サーバのルーティングと起動時処理 (Go 版 server.go 相当)。
  待ち受けは :gen_tcp、接続はアクセプタプロセスがそのまま処理する。
  """
  alias Amezo.{Admin, Config, Dai, Exit, Jump, Post, Req, Resp, Store, Sys, Util}

  @allowed_cgi ["amezo", "dai", "admin", "jump"]
  @static_root_files ["/", "/index.html", "/style.css", "/hide.js", "/ad.html"]
  @max_post_bytes_server 65_536

  def port do
    case System.get_env("AMEZO_PORT") do
      nil -> 8000
      "" -> 8000
      s -> Util.safe_integer(s, 8000)
    end
  end

  def tunnel?, do: System.get_env("AMEZO_TUNNEL") == "1"
  def verbose?, do: System.get_env("AMEZO_VERBOSE") == "1"

  # ---------- 起動時のディレクトリ準備 (setupBBSDirectories) ----------
  def setup_directories do
    IO.puts("📂 BBS用のディレクトリとパーミッションを設定しています...")

    for needed <- ["index.html", "style.css", "hide.js", "header.html", "blist.txt"] do
      if not Util.file_regular?(Config.app_path(needed)) do
        IO.puts(" ⚠️ #{needed} が見つかりません")
      end
    end

    if not Util.file_regular?(Config.app_path("delpass.txt")) do
      IO.puts(" ℹ️ delpass.txt がありません。管理画面を使うなら: ./run.sh --make-hash 合言葉")
    end

    for board <- Store.board_folders() do
      File.mkdir_p(Config.app_path(board))
      index = Config.app_path([board, "index.html"])
      {sz, _} = Util.file_size(index)

      if not Util.file_regular?(index) or sz < 100 do
        Util.write_file_string(
          index,
          "<html><head><meta http-equiv=\"refresh\" content=\"0;url=../amezo.cgi?folder=#{board}\"></head><body>Redirecting to BBS...</body></html>\n"
        )

        Util.set_file_mtime(index, Util.epoch_now() - 3600)
        IO.puts(" - 初期リダイレクト用ファイルを配置: #{board}/index.html")
      end
    end
  end

  # ---------- パスの検査 (Python 版 is_malformed_path) ----------
  def malformed_path?(raw_path) do
    raw_path == "" or not String.starts_with?(raw_path, "/") or
      String.contains?(raw_path, "//") or String.contains?(raw_path, "%") or
      String.contains?(raw_path, "\\") or String.contains?(raw_path, <<0>>) or
      String.contains?(raw_path, "..") or
      Enum.any?(String.split(raw_path, "/"), fn p -> p == "." end)
  end

  def accepts_gzip?(header) do
    Enum.any?(String.split(header, ","), fn tok ->
      parts = tok |> String.split(";") |> Enum.map(&Util.trim_space/1)
      name = String.downcase(hd(parts))

      if name == "gzip" or name == "x-gzip" do
        q =
          Enum.reduce(tl(parts), 1.0, fn p, acc ->
            if byte_size(p) > 2 and String.downcase(binary_part(p, 0, 2)) == "q=" do
              case Float.parse(Util.trim_space(binary_part(p, 2, byte_size(p) - 2))) do
                {v, _} -> v
                :error -> acc
              end
            else
              acc
            end
          end)

        q > 0
      else
        false
      end
    end)
  end

  # ---------- ルーティング ----------
  def board_file_allowed?(name) do
    if String.ends_with?(name, ".html") do
      base = binary_part(name, 0, byte_size(name) - 5)

      cond do
        base == "kako" ->
          true

        String.starts_with?(base, "index") ->
          byte_size(base) == 5 or Util.digits?(binary_part(base, 5, byte_size(base) - 5), 1, -1)

        base != "" and Util.all_digits?(base) ->
          true

        byte_size(base) > 1 and :binary.at(base, 0) == ?o ->
          Util.digits?(binary_part(base, 1, byte_size(base) - 1), 1, -1)

        true ->
          false
      end
    else
      false
    end
  end

  def static_allowed?(path) do
    cond do
      path in @static_root_files ->
        true

      byte_size(path) <= 1 ->
        false

      true ->
        {board, tail, found} = Util.split_once(binary_part(path, 1, byte_size(path) - 1), ?/)

        Store.is_board(board) and
          (not found or tail == "" or board_file_allowed?(tail))
    end
  end

  def static_file_path(path) do
    cond do
      path == "/" or path == "/index.html" ->
        Config.app_path("index.html")

      path in @static_root_files ->
        Config.app_path(binary_part(path, 1, byte_size(path) - 1))

      true ->
        {board, tail, _} = Util.split_once(binary_part(path, 1, byte_size(path) - 1), ?/)

        if tail == "" do
          Config.app_path([board, "index.html"])
        else
          Config.app_path([board, tail])
        end
    end
  end

  # /xxx.cgi か /xxx.py なら xxx (許可されたものだけ)。それ以外は ""
  def cgi_name(path) do
    if byte_size(path) <= 1 do
      ""
    else
      rest = binary_part(path, 1, byte_size(path) - 1)

      if String.contains?(rest, "/") do
        ""
      else
        {base, ext, found} = Util.split_once(rest, ?.)

        if found and (ext == "cgi" or ext == "py") and base in @allowed_cgi do
          base
        else
          ""
        end
      end
    end
  end

  def archived_gz_path(raw_path) do
    parts = Util.split_no_empty(raw_path, "/")

    with [board, name] <- parts,
         true <- Store.is_board(board),
         true <- byte_size(name) > 6 and :binary.at(name, 0) == ?o and String.ends_with?(name, ".html"),
         true <- Util.digits?(binary_part(name, 1, byte_size(name) - 6), 1, -1) do
      plain = Config.app_path([board, name])
      gz = Config.app_path([board, name <> ".gz"])

      if Util.file_regular?(gz) do
        cond do
          not Util.file_regular?(plain) ->
            gz

          true ->
            {pm, _} = Util.file_mtime(plain)
            {gm, _} = Util.file_mtime(gz)
            if pm == gm, do: gz, else: ""
        end
      else
        ""
      end
    else
      _ -> ""
    end
  end

  defp error_resp(status, message) do
    %Resp{status: status, headers: [{"Content-Type", "text/plain; charset=UTF-8"}], body: message}
  end

  def serve_archived(gz, accept) do
    common = [
      {"Content-Type", "text/html; charset=UTF-8"},
      {"Vary", "Accept-Encoding"},
      {"X-Content-Type-Options", "nosniff"},
      {"Cache-Control", "public, max-age=3600"}
    ]

    if accepts_gzip?(accept) do
      case File.read(gz) do
        {:ok, data} -> %Resp{status: 200, headers: common ++ [{"Content-Encoding", "gzip"}], body: data}
        _ -> error_resp(404, "Not Found")
      end
    else
      case Sys.gunzip_to_string(gz) do
        {plain, true} -> %Resp{status: 200, headers: common, body: plain}
        _ -> error_resp(404, "Not Found")
      end
    end
  end

  def dispatch_cgi(name, %Req{} = req) do
    Exit.run_handler(fn ->
      case name do
        "amezo" -> Post.handle_amezo(req)
        "dai" -> Dai.handle_dai(req)
        "admin" -> Admin.handle_admin(req)
        "jump" -> Jump.handle_jump(req)
      end
    end)
  rescue
    e ->
      IO.puts(:stderr, "amezo: #{name} の処理でエラー: #{Exception.message(e)}")

      %Resp{
        status: 500,
        headers: [{"Content-Type", "text/plain; charset=UTF-8"}],
        body: "Internal Server Error"
      }
  end

  @doc """
  1 リクエスト分のルーティング。{応答, head_only} を返す。
  応答せずに接続を閉じる場合は :close。
  """
  def route(%Req{} = req, raw_path, content_length) do
    head_only = req.method == "HEAD"

    cond do
      # 本体サイズの検査はルーティングより先 (Python 版と同じ)
      content_length > @max_post_bytes_server ->
        error_resp(413, "Payload Too Large")

      malformed_path?(raw_path) ->
        error_resp(400, "Bad Request")

      true ->
        route_ok(req, raw_path, head_only)
    end
  end

  defp route_ok(%Req{} = req, raw_path, head_only) do
    gz =
      if req.method in ["GET", "HEAD"] do
        archived_gz_path(raw_path)
      else
        ""
      end

    cond do
      gz != "" ->
        serve_archived(gz, Req.header(req, "Accept-Encoding"))

      cgi_name(raw_path) != "" ->
        if req.method in ["GET", "POST", "HEAD"] do
          req = if head_only, do: %{req | method: "GET"}, else: req
          dispatch_cgi(cgi_name(raw_path), req)
        else
          # 許可メソッド以外は Lisp 版と同じく応答しない (接続を閉じる)
          :close
        end

      req.method in ["GET", "HEAD"] ->
        if not static_allowed?(raw_path) do
          error_resp(404, "Not Found")
        else
          path = static_file_path(raw_path)

          case File.read(path) do
            {:ok, data} ->
              ctype =
                cond do
                  String.ends_with?(path, ".css") -> "text/css"
                  String.ends_with?(path, ".js") -> "text/javascript"
                  true -> "text/html"
                end

              %Resp{status: 200, headers: [{"Content-Type", ctype}], body: data}

            _ ->
              error_resp(404, "Not Found")
          end
        end

      req.method == "POST" ->
        error_resp(501, "Can only POST to CGI scripts")

      true ->
        error_resp(501, "Not Implemented")
    end
  end

  # ---------- 自己チェック ----------
  def http_status(port, path) do
    case :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, packet: :raw, active: false], 3000) do
      {:ok, sock} ->
        :gen_tcp.send(sock, "GET #{path} HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n")

        code =
          case :gen_tcp.recv(sock, 0, 5000) do
            {:ok, data} ->
              first = data |> String.split("\r\n") |> hd() |> String.split(" ")

              case first do
                [_, code_s | _] -> Util.safe_integer(code_s, 0)
                _ -> 0
              end

            _ ->
              0
          end

        :gen_tcp.close(sock)
        code

      _ ->
        0
    end
  end

  def self_check(port) do
    IO.puts("🔎 起動チェック:")

    checks = [
      {"/dai.cgi", 200},
      {"/jump.cgi", 200},
      {"/style.css", 200},
      {"/hide.js", 200},
      {"//amezo.py", 400},
      {"/setup_expose.py", 404},
      {"/amezo.ex", 404},
      {"/trip_secret.txt", 404},
      {"/id_secret.txt", 404},
      {"/delpass.txt", 404},
      {"/cap.txt", 404},
      {"/blist.txt", 404},
      {"/config.ini", 404},
      {"/key_secret.txt", 404},
      {"/jump_secret.txt", 404},
      {"/ng.txt", 404},
      {"/server.ex", 404},
      {"//archive.py", 400}
    ]

    good =
      Enum.all?(checks, fn {path, want} ->
        got = http_status(port, path)
        ok = got == want
        mark = if ok, do: "✅", else: "❌"
        note = if ok, do: "", else: " (期待: #{want})"
        IO.puts(" #{mark} #{path} -> #{got}#{note}")
        ok
      end)

    if not good do
      IO.puts(" ⚠️ 期待と違う結果があります。公開する前に server.ex の配信判定を確認してください。")
    end

    good
  end
end

defmodule Amezo.Server.Listener do
  @moduledoc ":gen_tcp の待ち受けとアクセプタの監督"
  use GenServer

  @acceptors 8

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    port = Keyword.get(opts, :port, 8000)

    case :gen_tcp.listen(port, [:binary, packet: :raw, active: false, reuseaddr: true, ip: {127, 0, 0, 1}]) do
      {:ok, lsock} ->
        IO.puts("🚀 Webサーバーを起動しています (ポート #{port})...")
        Process.flag(:trap_exit, true)
        {:ok, %{lsock: lsock, port: port, acceptors: []}, {:continue, :spawn}}

      {:error, reason} ->
        IO.puts(:stderr, "❌ サーバーを起動できませんでした: #{inspect(reason)}")
        {:stop, reason}
    end
  end

  @impl true
  def handle_continue(:spawn, state) do
    acceptors = for _ <- 1..@acceptors, do: spawn_acceptor(state.lsock)
    {:noreply, %{state | acceptors: acceptors}}
  end

  @impl true
  def handle_info({:EXIT, pid, _reason}, state) do
    if pid in state.acceptors do
      {:noreply, %{state | acceptors: [spawn_acceptor(state.lsock) | List.delete(state.acceptors, pid)]}}
    else
      {:noreply, state}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp spawn_acceptor(lsock) do
    spawn_link(fn -> Amezo.Server.Acceptor.loop(lsock) end)
  end
end

defmodule Amezo.Server.Acceptor do
  @moduledoc "accept して、そのまま接続を処理して、また accept に戻る"
  alias Amezo.Server.Conn

  def loop(lsock) do
    case :gen_tcp.accept(lsock) do
      {:ok, sock} ->
        Conn.handle(sock)
        loop(lsock)

      {:error, _} ->
        # 待ち受けソケットが閉じた等。少し待って抜ける (Listener が張り直す)
        Process.sleep(100)
        :ok
    end
  end
end

defmodule Amezo.Server.Conn do
  @moduledoc "1 接続分の読み取り → ルーティング → 書き込み"
  alias Amezo.{Req, Resp, Server, Util}

  @recv_timeout 10_000
  @max_header_bytes 65_536

  def handle(sock) do
    try do
      do_handle(sock)
    rescue
      e -> IO.puts(:stderr, "amezo: 接続処理でエラー: #{Exception.message(e)}")
    catch
      _, _ -> :ok
    after
      :gen_tcp.close(sock)
    end
  end

  defp do_handle(sock) do
    case read_head(sock, "") do
      {:ok, head, rest} ->
        case parse_head(head) do
          {:ok, method, target, headers} ->
            serve(sock, method, target, headers, rest)

          :error ->
            :ok
        end

      :error ->
        :ok
    end
  end

  defp read_head(sock, acc) do
    cond do
      byte_size(acc) > @max_header_bytes ->
        :error

      true ->
        case :binary.match(acc, "\r\n\r\n") do
          {i, 4} ->
            {:ok, binary_part(acc, 0, i), binary_part(acc, i + 4, byte_size(acc) - i - 4)}

          :nomatch ->
            case :gen_tcp.recv(sock, 0, @recv_timeout) do
              {:ok, data} -> read_head(sock, acc <> data)
              _ -> :error
            end
        end
    end
  end

  defp parse_head(head) do
    lines = String.split(head, "\r\n")

    case lines do
      [request_line | header_lines] ->
        case String.split(request_line, " ") do
          [method, target, _version] ->
            headers =
              Enum.flat_map(header_lines, fn line ->
                case Util.split_once(line, ?:) do
                  {k, v, true} -> [{Util.trim_space(k), Util.trim_space(v)}]
                  _ -> []
                end
              end)

            {:ok, method, target, headers}

          _ ->
            :error
        end

      _ ->
        :error
    end
  end

  defp serve(sock, method, target, headers, rest) do
    {raw_path, query} =
      case Util.split_once(target, ??) do
        {p, q, true} -> {p, q}
        {p, _, false} -> {p, ""}
      end

    if Server.verbose?() do
      IO.puts(" #{method} #{target}")
    end

    cl =
      case Enum.find(headers, fn {k, _} -> String.downcase(k) == "content-length" end) do
        {_, v} -> Util.safe_integer(v, 0)
        nil -> 0
      end

    head_only = method == "HEAD"

    cond do
      cl > 65_536 ->
        write_resp(sock, Server.route(make_req(method, query, "", headers, sock, raw_path), raw_path, cl), head_only)

      true ->
        case read_body(sock, rest, cl) do
          {:ok, body} ->
            req = make_req(method, query, body, headers, sock, raw_path)
            write_resp(sock, Server.route(req, raw_path, cl), head_only)

          :error ->
            :ok
        end
    end
  end

  defp read_body(_sock, acc, n) when byte_size(acc) >= n do
    {:ok, binary_part(acc, 0, n)}
  end

  defp read_body(sock, acc, n) do
    case :gen_tcp.recv(sock, n - byte_size(acc), @recv_timeout) do
      {:ok, data} -> read_body(sock, acc <> data, n)
      _ -> :error
    end
  end

  defp make_req(method, query, body, headers, sock, raw_path) do
    remote =
      case :inet.peername(sock) do
        {:ok, {ip, _port}} -> ip |> :inet.ntoa() |> to_string()
        _ -> "127.0.0.1"
      end

    %Req{
      method: method,
      query_string: query,
      body: body,
      headers: headers,
      remote_addr: remote,
      script_name: raw_path
    }
  end

  defp write_resp(_sock, :close, _head_only), do: :ok

  defp write_resp(sock, %Resp{} = resp, head_only) do
    has_len = Enum.any?(resp.headers, fn {k, _} -> String.downcase(k) == "content-length" end)

    headers =
      if has_len do
        resp.headers
      else
        resp.headers ++ [{"Content-Length", Integer.to_string(byte_size(resp.body))}]
      end

    head =
      "HTTP/1.1 #{resp.status} #{reason(resp.status)}\r\n" <>
        Enum.map_join(headers, "", fn {k, v} -> "#{k}: #{v}\r\n" end) <>
        "Connection: close\r\n\r\n"

    :gen_tcp.send(sock, head)
    if not head_only, do: :gen_tcp.send(sock, resp.body)
    :ok
  end

  defp reason(status) do
    case status do
      200 -> "OK"
      303 -> "See Other"
      400 -> "Bad Request"
      404 -> "Not Found"
      413 -> "Payload Too Large"
      500 -> "Internal Server Error"
      501 -> "Not Implemented"
      _ -> "Status"
    end
  end
end

defmodule Amezo.Server.Boot do
  @moduledoc "起動確認と自己チェック (serve モードの最後尾で一度だけ走る)"
  use GenServer
  alias Amezo.Server

  def start_link(_arg) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @impl true
  def init(_), do: {:ok, %{}, {:continue, :boot}}

  @impl true
  def handle_continue(:boot, state) do
    port = Server.port()
    wait_ready(port, 50)

    if Server.http_status(port, "/style.css") == 200 do
      IO.puts("✅ Webサーバーがポート #{port} で正常に応答しました。")
    end

    Server.self_check(port)

    if not Server.tunnel?() do
      IO.puts("\n🏠 ローカルで起動しました: http://127.0.0.1:#{port}/")
    end

    IO.puts("\n⏳ サーバー稼働中... 停止するには Ctrl+C を押してください。")
    {:noreply, state}
  end

  defp wait_ready(_port, 0), do: :ok

  defp wait_ready(port, n) do
    if Server.http_status(port, "/style.css") == 200 do
      :ok
    else
      Process.sleep(200)
      wait_ready(port, n - 1)
    end
  end
end
