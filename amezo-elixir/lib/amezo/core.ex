defmodule Amezo.Core do
  @moduledoc """
  共通部分: 秘密鍵の取得、トリップ / ID / キャップ、投稿制限、中継リンク (linkify)。
  Go 版 core.go と同じ挙動 (url_is_valid と linkify は仕様の正本である Python 版の
  ASCII 文字クラスに合わせる)。
  """
  alias Amezo.{Config, Counters, Crypto, Exit, Req, Secrets, Store, Util}

  # ---------- 秘密鍵 ----------
  defp secret_or_error(which, msg) do
    case Secrets.key(which) do
      nil -> Exit.page_error(msg)
      k -> k
    end
  end

  def trip_key, do: secret_or_error(:trip, "トリップ用の鍵を保存できません.")
  def id_key, do: secret_or_error(:id, "ID用の鍵を保存できません.")
  def key_secret_key, do: secret_or_error(:key, "認証キー用の鍵を保存できません.")
  def jump_secret_key, do: secret_or_error(:jump, "中継用の鍵を保存できません.")

  # ---------- クライアント IP ----------
  def client_ip(%Req{} = req) do
    addr = req.remote_addr

    if addr in Config.trusted_proxies() do
      cf = Req.header(req, "CF-Connecting-IP")

      cond do
        cf != "" and Util.ip_valid?(cf) ->
          cf

        true ->
          xff = Req.header(req, "X-Forwarded-For")
          parts = String.split(xff, ",")
          last = parts |> List.last() |> Util.trim_space()

          if last != "" and Util.ip_valid?(last) do
            last
          else
            addr
          end
      end
    else
      addr
    end
  end

  # ---------- トリップ / ID / キャップ ----------
  def clean_trip_password(password) do
    password
    |> Util.codepoints_list()
    |> Enum.reject(fn c -> c == ?\s or c == 0x3000 end)
    |> Enum.map(fn c -> if c >= 0xFF01 and c <= 0xFF5E, do: c - 0xFEE0, else: c end)
    |> Enum.take(Config.trip_pass_max())
    |> Util.codepoints_to_string()
  end

  defp trip_transform(b64) do
    b64 |> String.replace("+", ".") |> String.replace("/", "_")
  end

  def make_trip(password) do
    pw = clean_trip_password(password)

    if pw == "" do
      ""
    else
      digest = Crypto.hmac_sha256(trip_key(), pw)
      trip_transform(binary_part(Crypto.base64_encode(digest), 0, 10))
    end
  end

  def make_id(ip, board, epoch) do
    {y, m, d, _, _, _, _} = Util.epoch_to_jst(epoch)

    ymd =
      :io_lib.format("~4..0B~2..0B~2..0B", [y, m, d]) |> IO.iodata_to_binary()

    msg = Config.id_ctx() <> Util.ip_unit(ip) <> "|" <> ymd <> "|" <> board

    digest = Crypto.hmac_sha256(id_key(), msg)
    trip_transform(binary_part(Crypto.base64_encode(digest), 0, Config.id_len()))
  end

  def remove_name_spaces(s) do
    s
    |> Util.codepoints_list()
    |> Enum.reject(fn c -> c == ?\s or c == 0x3000 or c == 0x200D end)
    |> Util.codepoints_to_string()
  end

  def is_cap(name_escaped, password), do: Store.is_cap(name_escaped, password)

  # ---------- 投稿制限 ----------
  # 板プロセスの状態にある最終投稿時刻から残り秒を返す
  def post_interval_left(folder) do
    interval = Config.post_interval()

    if interval <= 0 do
      0
    else
      last = Amezo.Board.get_state(folder, :last_post_at, 0)
      left = interval - (Util.epoch_now() - last)
      if left > 0, do: left, else: 0
    end
  end

  # Board.run の中で呼ぶ
  def touch_lasttime_board do
    if Config.post_interval() > 0 do
      Amezo.Board.state_put(:last_post_at, Util.epoch_now())
    end
  end

  # 同じ接続元の新規スレッドを global_window 秒止める (Python 版 check_global_ip)
  def check_global_ip(req) do
    ip = client_ip(req)
    who = binary_part(Crypto.hmac_sha256_hex(id_key(), Config.rl_ctx() <> Util.ip_unit(ip)), 0, 24)

    case Counters.global_check_and_add(who, Config.global_window()) do
      :ok -> :ok
      {:wait, secs} -> Exit.page_error("あと #{secs} 秒たってから投稿してください")
    end
  end

  # ---------- 中継リンク ----------
  defp ascii_alnum?(c), do: (c >= ?a and c <= ?z) or (c >= ?A and c <= ?Z) or (c >= ?0 and c <= ?9)

  @url_chars ~c"-._~:/?#[]@!$*+,;=%()'&"

  def url_is_valid(url) do
    cond do
      url == "" or byte_size(url) > Config.url_max_len() ->
        false

      true ->
        prefix_len =
          cond do
            String.starts_with?(url, "http://") -> 7
            String.starts_with?(url, "https://") -> 8
            true -> 0
          end

        if prefix_len == 0 or prefix_len >= byte_size(url) do
          false
        else
          <<_::binary-size(prefix_len), first, rest::binary>> = url

          (ascii_alnum?(first) or first == ?[) and
            Enum.all?(:binary.bin_to_list(<<first, rest::binary>>), fn c ->
              ascii_alnum?(c) or c in @url_chars
            end)
        end
    end
  end

  def jump_sign(url) do
    binary_part(
      Crypto.b64url_encode(Crypto.hmac_sha256(jump_secret_key(), Config.jump_ctx() <> url)),
      0,
      Config.jump_sig_len()
    )
  end

  def jump_verify(url, sig) do
    url_is_valid(url) and Crypto.constant_time_string_equal(jump_sign(url), sig)
  end

  def jump_href(url) do
    "../jump.cgi?u=" <> Crypto.b64url_encode(url) <> "&amp;s=" <> jump_sign(url)
  end

  @linkify_chars ~c"-._~:/?#[]@!$*+,;=%()"

  # エスケープ済み本文の URL をリンクにする (Python 版 linkify_urls)
  def linkify_urls(escaped, jump) do
    linkify_scan(escaped, jump, [])
  end

  defp linkify_scan(rest, jump, acc) do
    case :binary.match(rest, ["http://", "https://"]) do
      :nomatch ->
        IO.iodata_to_binary(Enum.reverse([rest | acc]))

      {start, _len} ->
        before = binary_part(rest, 0, start)
        tail_all = binary_part(rest, start, byte_size(rest) - start)
        {match, after_match} = take_url_body(tail_all)
        replacement = linkify_replacement(match, jump)
        linkify_scan(after_match, jump, [replacement, before | acc])
    end
  end

  defp take_url_body(s), do: take_url_body(s, 0)
  defp take_url_body(s, n) do
    rest = binary_part(s, n, byte_size(s) - n)

    cond do
      String.starts_with?(rest, "&amp;") ->
        take_url_body(s, n + 5)

      String.starts_with?(rest, "&#39;") ->
        take_url_body(s, n + 5)

      rest != "" ->
        <<c, _::binary>> = rest

        if ascii_alnum?(c) or c in @linkify_chars do
          take_url_body(s, n + 1)
        else
          {binary_part(s, 0, n), rest}
        end

      true ->
        {s, ""}
    end
  end

  defp linkify_replacement(match, jump) do
    {dsp, tail} = strip_url_tail(match, "")

    url =
      dsp
      |> String.replace("&amp;", "&")
      |> String.replace("&#39;", "'")

    if url_is_valid(url) do
      href = if jump, do: jump_href(url), else: Util.html_escape(url)
      "<a href=\"" <> href <> "\" target=\"_blank\" rel=\"noopener noreferrer nofollow\">" <> dsp <> "</a>" <> tail
    else
      match
    end
  end

  defp strip_url_tail(dsp, tail) do
    cond do
      dsp == "" ->
        {dsp, tail}

      String.ends_with?(dsp, "&amp;") or String.ends_with?(dsp, "&#39;") ->
        cut = byte_size(dsp) - 5
        strip_url_tail(binary_part(dsp, 0, cut), binary_part(dsp, cut, 5) <> tail)

      true ->
        last = :binary.last(dsp)

        cond do
          last in [?., ?,, ?;, ?:, ?!, ??, ?(] ->
            cut = byte_size(dsp) - 1
            strip_url_tail(binary_part(dsp, 0, cut), binary_part(dsp, cut, 1) <> tail)

          last == ?) and count_byte(dsp, ?)) > count_byte(dsp, ?() ->
            cut = byte_size(dsp) - 1
            strip_url_tail(binary_part(dsp, 0, cut), ")" <> tail)

          last == ?] and count_byte(dsp, ?]) > count_byte(dsp, ?[) ->
            cut = byte_size(dsp) - 1
            strip_url_tail(binary_part(dsp, 0, cut), "]" <> tail)

          true ->
            {dsp, tail}
        end
    end
  end

  defp count_byte(s, byte), do: length(:binary.matches(s, <<byte>>))

  # ---------- 返信フォーム ----------
  def reply_form(res, links, locked) do
    locked_html =
      if locked do
        "<div class=\"row\">🔒 認証キー <input type=password name=\"key\" size=32 autocomplete=off required> このスレッドは認証キーがないと書き込めません</div>"
      else
        ""
      end

    "<form method=post action=\"../amezo.cgi\" class=\"post\"><input type=hidden name=\"res\" value=\"" <>
      res <>
      "\"><div class=\"row\">投稿者 <input type=text name=\"name\" size=20> メール <input type=text name=\"mail\" size=20 maxlength=50></div>" <>
      locked_html <>
      "<textarea name=\"comm\" rows=4 cols=70 maxlength=400></textarea><div class=\"row\"><input type=submit value=\"↑へのレスカキコ\"></div>" <>
      links <> "</form>"
  end
end
