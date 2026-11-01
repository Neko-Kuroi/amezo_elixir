defmodule Amezo.Config do
  @moduledoc """
  設定値と config.ini (Python 版 amezo.config_load と同じ検査)。
  起動時に load_config/0 が検査を通った値だけを :persistent_term に反映する。
  """
  alias Amezo.Util

  @copyright_text "<!--\n    Script for amezo-like BBS (Elixir Version)\n    Original Copyright (C) 1999-2003 amezo_\n    http://www17.big.or.jp/~amezo_/\n    http://ame.x0.com/\n-->\n"

  # ---------- 固定値 ----------
  def copyright_text, do: @copyright_text
  def kako_file, do: "kako.html"
  def kako_list, do: "kako.txt"
  def kako_sep, do: "<>"
  def per_page, do: 20
  def headline_count, do: 100
  def delcrypt_file, do: "delpass.txt"
  def trip_secret_file, do: "trip_secret.txt"
  def id_secret_file, do: "id_secret.txt"
  def id_len, do: 8
  def script_tag, do: ~s(<script src="../hide.js" defer></script>)
  def id_ctx, do: "id:"
  def rl_ctx, do: "rl:"
  def trip_pass_max, do: 100
  def trip_mark, do: "◆"
  def cap_mark, do: "★"
  def cap_file, do: "cap.txt"
  def key_secret_file, do: "key_secret.txt"
  def key_ctx, do: "key:"
  def keys_file, do: "keys.txt"
  def key_alphabet, do: "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567"
  def jump_secret_file, do: "jump_secret.txt"
  def jump_ctx, do: "jump:"
  def jump_sig_len, do: 22
  def url_max_len, do: 2000

  # ---------- アプリのルート ----------
  def app_dir do
    dir = System.get_env("AMEZO_DIR") || File.cwd!()
    String.trim_trailing(dir, "/") <> "/"
  end

  def app_path(parts) when is_list(parts), do: app_dir() <> Enum.join(parts, "/")
  def app_path(part), do: app_dir() <> part

  # ---------- 設定値 (config.ini で上書き可能) ----------
  defp settings, do: :persistent_term.get(:amezo_config, %{})

  defp get(key, default), do: Map.get(settings(), key, default)

  def amezo_name, do: get("AMEZO", "＠あめぞう")
  def urlbase, do: get("URLBASE", "http://ame.x0.com/")
  def admin_name, do: get("ADMIN", "サポート")
  def post_interval, do: get("POST_INTERVAL", 5)
  def global_window, do: get("GLOBAL_WINDOW", 180)
  def max_threads, do: get("MAX_THREADS", 200)
  def jump_enabled, do: get("JUMP_ENABLED", true)
  def archive_quiet_seconds, do: get("ARCHIVE_QUIET_SECONDS", 600)
  def max_post_bytes, do: get("MAX_POST_BYTES", 7500)
  def subj_max, do: get("SUBJ_MAX", 45)
  def name_max, do: get("NAME_MAX", 25)
  def mail_max, do: get("MAIL_MAX", 50)
  def comm_max, do: get("COMM_MAX", 400)
  def comm_lines_max, do: get("COMM_LINES_MAX", 20)
  def page_cache, do: get("PAGE_CACHE", 10)
  def hash_iterations, do: get("HASH_ITERATIONS", 100_000)
  def trusted_proxies, do: get("TRUSTED_PROXIES", ["127.0.0.1", "::1"])

  # ---------- スキーマと検査 ----------
  # {名前, 型, 既定値, 最小, 最大}
  def config_schema do
    [
      {"AMEZO", "text", "＠あめぞう", 0, 40},
      {"URLBASE", "url", "http://ame.x0.com/", 0, 200},
      {"ADMIN", "text", "サポート", 1, 20},
      {"POST_INTERVAL", "int", 5, 0, 3600},
      {"GLOBAL_WINDOW", "int", 180, 0, 86400},
      {"MAX_THREADS", "int", 200, 0, 100000},
      {"PAGE_CACHE", "int", 10, 0, 3600},
      {"MAX_POST_BYTES", "int", 7500, 1000, 1000000},
      {"SUBJ_MAX", "int", 45, 1, 500},
      {"NAME_MAX", "int", 25, 1, 200},
      {"MAIL_MAX", "int", 50, 1, 500},
      {"COMM_MAX", "int", 400, 1, 10000},
      {"COMM_LINES_MAX", "int", 20, 1, 1000},
      {"HASH_ITERATIONS", "int", 100000, 1000, 5000000},
      {"TRUSTED_PROXIES", "ips", ["127.0.0.1", "::1"], 0, 16},
      {"JUMP_ENABLED", "bool", true, 0, 1},
      {"ARCHIVE_QUIET_SECONDS", "int", 600, 0, 604800}
    ]
  end

  # 1つの値を検査する。{直した値, true} か {nil, 理由}
  def config_check("int", v, min, max) when is_binary(v) do
    s = Util.trim_space(v)
    # 先頭の '-' は最大でも1つだけ外す (Go 版 TrimPrefix と同じ)
    body =
      case s do
        "-" <> rest -> rest
        _ -> s
      end

    ok = s != "" and Util.codepoint_count(s) <= 12 and body != "" and Util.digits?(body, 1, -1)

    if ok do
      n = Util.safe_integer(s, nil)

      cond do
        is_nil(n) -> {nil, "整数ではありません"}
        n < min or n > max -> {nil, "#{min}〜#{max} の範囲外です"}
        true -> {n, true}
      end
    else
      {nil, "整数ではありません"}
    end
  end

  def config_check("bool", v, _min, _max) when is_binary(v) do
    case v |> Util.trim_space() |> String.downcase() do
      x when x in ["1", "true", "yes", "on"] -> {true, true}
      x when x in ["0", "false", "no", "off"] -> {false, true}
      _ -> {nil, "true / false ではありません"}
    end
  end

  def config_check("text", v, min, max) when is_binary(v) do
    bad =
      Enum.any?(Util.codepoints_list(v), fn c ->
        c <= 0x1F or c == 0x7F or c in [?<, ?>, ?", ?', ?&, ?$, ?\\]
      end)

    cond do
      bad -> {nil, "使えない文字 (制御文字 < > \" ' & $ \\) を含みます"}
      Util.codepoint_count(v) < min or Util.codepoint_count(v) > max -> {nil, "#{min}〜#{max} 文字ではありません"}
      true -> {v, true}
    end
  end

  def config_check("url", v, _min, max) when is_binary(v) do
    reason = "http:// か https:// で始まる URL ではありません"

    cond do
      byte_size(v) > max ->
        {nil, reason}

      v == "" ->
        {v, true}

      true ->
        prefix_len =
          cond do
            String.starts_with?(v, "http://") -> 7
            String.starts_with?(v, "https://") -> 8
            true -> 0
          end

        if prefix_len == 0 or prefix_len >= byte_size(v) do
          {nil, reason}
        else
          <<_::binary-size(prefix_len), first, rest::binary>> = v

          if alnum_byte?(first) and
               Enum.all?(<<first, rest::binary>> |> :binary.bin_to_list(), fn c ->
                 alnum_byte?(c) or c in [?., ?-, ?:, ?/, ?_]
               end) do
            {v, true}
          else
            {nil, reason}
          end
        end
    end
  end

  def config_check("ips", v, _min, max) do
    cond do
      is_binary(v) ->
        if v == "", do: {[], true}, else: {nil, "IP アドレスの並びではありません"}

      is_list(v) ->
        if length(v) > max do
          {nil, "IP アドレスの並びではありません"}
        else
          trimmed = Enum.map(v, &Util.trim_space/1)

          if Enum.all?(trimmed, &Util.ip_valid?/1) do
            {trimmed, true}
          else
            {nil, "IP アドレスではない値があります"}
          end
        end

      true ->
        {nil, "IP アドレスの並びではありません"}
    end
  end

  def config_check(_typ, _v, _min, _max), do: {nil, "未対応の型です"}

  defp alnum_byte?(c),
    do: (c >= ?a and c <= ?z) or (c >= ?A and c <= ?Z) or (c >= ?0 and c <= ?9) or c >= 0x80

  # ---------- INI 解析 ----------
  # INI の値の後処理: 引用符を外し、';' コメントを取り、空白を詰める
  def ini_clean_value(<<"\"", rest::binary>> = v) do
    case :binary.match(rest, "\"") do
      {idx, 1} -> binary_part(rest, 0, idx)
      :nomatch -> v
    end
  end

  def ini_clean_value(v) do
    v = cut_at(v, " ;")
    v = cut_at(v, "\t;")
    Util.trim_space(v)
  end

  defp cut_at(s, pat) do
    case :binary.match(s, pat) do
      {idx, _} -> binary_part(s, 0, idx)
      :nomatch -> s
    end
  end

  # INI の生の値を読む (展開はしない)。書き方の誤りがあれば :error。
  def parse_ini_raw(text) do
    result =
      Enum.reduce_while(String.split(text, "\n"), {:ok, []}, fn line, {:ok, raw} ->
        s = line |> String.trim_trailing("\r") |> Util.trim_space()

        cond do
          s == "" or String.starts_with?(s, ";") or String.starts_with?(s, "#") ->
            {:cont, {:ok, raw}}

          String.starts_with?(s, "[") or not String.contains?(s, "=") ->
            {:halt, :error}

          true ->
            {k, v, _} = Util.split_once(s, ?=)
            k = Util.trim_space(k)
            v = Util.trim_space(v)

            if k == "" do
              {:halt, :error}
            else
              is_list = String.ends_with?(k, "[]")
              k = if is_list, do: k |> binary_part(0, byte_size(k) - 2) |> Util.trim_space(), else: k
              v = ini_clean_value(v)
              {:cont, {:ok, ini_put(raw, k, v, is_list)}}
            end
        end
      end)

    case result do
      {:ok, raw} -> {raw, true}
      :error -> {[], false}
    end
  end

  defp ini_put(raw, k, v, is_list) do
    case Enum.find_index(raw, fn {key, _} -> key == k end) do
      nil ->
        raw ++ [{k, if(is_list, do: [v], else: v)}]

      idx ->
        List.update_at(raw, idx, fn {key, prev} ->
          cond do
            is_list and is_list(prev) -> {key, prev ++ [v]}
            is_list -> {key, [prev, v]}
            true -> {key, v}
          end
        end)
    end
  end

  # config.ini を読み、検査を通った値だけを返す。{値, 無視した理由のリスト}
  def config_load(path) do
    unreadable = {%{}, ["読み込めません (書き方の誤り)"]}

    with true <- Util.file_regular?(path),
         {text, true} <- Util.read_file_string(path),
         {raw, true} <- parse_ini_raw(text) do
      schema =
        Map.new(config_schema(), fn {name, typ, _d, min, max} -> {name, {typ, min, max}} end)

      Enum.reduce(raw, {%{}, []}, fn {key, val}, {out, errors} ->
        case Map.fetch(schema, key) do
          :error ->
            {out, errors ++ ["不明なキー: #{key}"]}

          {:ok, {typ, min, max}} ->
            case config_check(typ, val, min, max) do
              {fixed, true} -> {Map.put(out, key, fixed), errors}
              {_, reason} -> {out, errors ++ ["#{key}: #{reason}"]}
            end
        end
      end)
    else
      false -> {%{}, []}
      _ -> unreadable
    end
  end

  # config.ini を読み、検査を通った値だけを反映する (Python 版の起動時処理と同じ)
  def load_config do
    {values, errors} = config_load(app_path("config.ini"))

    Enum.each(errors, fn e ->
      IO.puts(:stderr, "amezo: config.ini の #{e} (無視して、既定値を使います)")
    end)

    :persistent_term.put(:amezo_config, values)

    if Util.file_regular?(app_path("config.php")) do
      IO.puts(
        :stderr,
        "amezo: config.php は読み込みません (実行される形式の設定は使いません)。config.ini に移してください"
      )
    end

    :ok
  end
end
