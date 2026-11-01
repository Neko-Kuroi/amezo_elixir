defmodule Amezo.Util do
  @moduledoc """
  文字列・ファイル・時刻・IP の土台 (Go 版 util.go と同じ挙動)。
  文字列は UTF-8 バイナリとして扱い、文字数はコードポイントで数える。
  """

  # ---------- UTF-8 ----------
  # 1文字を復号する。{コードポイント, バイト数}。壊れていれば {:error, 1}。
  def decode_rune(<<>>), do: {:error, 0}

  def decode_rune(bin) do
    case bin do
      <<c, _::binary>> when c < 0x80 ->
        {c, 1}

      <<c, b, _::binary>> when c in 0xC2..0xDF and b in 0x80..0xBF ->
        {Bitwise.bor(Bitwise.bsl(Bitwise.band(c, 0x1F), 6), Bitwise.band(b, 0x3F)), 2}

      <<0xE0, b, c2, _::binary>> when b in 0xA0..0xBF and c2 in 0x80..0xBF ->
        {cp3(0xE0, b, c2), 3}

      <<0xED, b, c2, _::binary>> when b in 0x80..0x9F and c2 in 0x80..0xBF ->
        {cp3(0xED, b, c2), 3}

      <<c, b, c2, _::binary>> when c in 0xE1..0xEF and b in 0x80..0xBF and c2 in 0x80..0xBF ->
        {cp3(c, b, c2), 3}

      <<0xF0, b, c2, c3, _::binary>> when b in 0x90..0xBF and c2 in 0x80..0xBF and c3 in 0x80..0xBF ->
        {cp4(0xF0, b, c2, c3), 4}

      <<0xF4, b, c2, c3, _::binary>> when b in 0x80..0x8F and c2 in 0x80..0xBF and c3 in 0x80..0xBF ->
        {cp4(0xF4, b, c2, c3), 4}

      <<c, b, c2, c3, _::binary>> when c in 0xF1..0xF3 and b in 0x80..0xBF and c2 in 0x80..0xBF and c3 in 0x80..0xBF ->
        {cp4(c, b, c2, c3), 4}

      _ ->
        {:error, 1}
    end
  end

  defp cp3(c, b, c2),
    do:
      Bitwise.bor(
        Bitwise.bor(Bitwise.bsl(Bitwise.band(c, 0x0F), 12), Bitwise.bsl(Bitwise.band(b, 0x3F), 6)),
        Bitwise.band(c2, 0x3F)
      )

  defp cp4(c, b, c2, c3),
    do:
      Bitwise.bor(
        Bitwise.bor(
          Bitwise.bsl(Bitwise.band(c, 0x07), 18),
          Bitwise.bsl(Bitwise.band(b, 0x3F), 12)
        ),
        Bitwise.bor(Bitwise.bsl(Bitwise.band(c2, 0x3F), 6), Bitwise.band(c3, 0x3F))
      )

  # バイト列を文字列にする。壊れた部分は置換文字 (U+FFFD)。
  def utf8_decode(octs), do: utf8_decode(octs, [])

  defp utf8_decode(<<>>, acc), do: acc |> Enum.reverse() |> IO.iodata_to_binary()

  defp utf8_decode(bin, acc) do
    case decode_rune(bin) do
      {:error, 0} ->
        utf8_decode(<<>>, acc)

      {:error, n} ->
        <<_::binary-size(n), rest::binary>> = bin
        utf8_decode(rest, [<<0xFFFD::utf8>> | acc])

      {cp, n} ->
        <<_::binary-size(n), rest::binary>> = bin
        utf8_decode(rest, [<<cp::utf8>> | acc])
    end
  end

  def codepoint_count(s), do: cp_count(s, 0)
  defp cp_count(<<>>, n), do: n

  defp cp_count(bin, n) do
    case decode_rune(bin) do
      {_, size} ->
        <<_::binary-size(size), rest::binary>> = bin
        cp_count(rest, n + 1)

      {:error, size} ->
        <<_::binary-size(size), rest::binary>> = bin
        cp_count(rest, n + 1)
    end
  end

  # 先頭から最大 n コードポイントまで (バイト列のまま切り取る)
  def cp_take(s, n), do: cp_take_bytes(s, n, 0)
  defp cp_take_bytes(_bin, n, i) when i >= n, do: ""
  defp cp_take_bytes(<<>>, _n, _i), do: ""

  defp cp_take_bytes(bin, n, i) do
    case decode_rune(bin) do
      {_, size} -> take_head(bin, size, n, i)
      {:error, size} -> take_head(bin, size, n, i)
    end
  end

  defp take_head(bin, size, n, i) do
    <<head::binary-size(size), rest::binary>> = bin
    head <> cp_take_bytes(rest, n, i + 1)
  end

  # ---------- 文字列 ----------
  # 前後の空白 (半角・タブ・改行・CR・全角空白) を取り除く
  def trim_space(s), do: s |> trim_left() |> trim_right()

  defp trim_left(<<c, rest::binary>>) when c in [?\s, ?\t, ?\n, ?\r], do: trim_left(rest)
  defp trim_left(<<0xE3, 0x80, 0x80, rest::binary>>), do: trim_left(rest)
  defp trim_left(s), do: s

  defp trim_right(""), do: ""

  defp trim_right(s) do
    cond do
      String.ends_with?(s, "　") ->
        trim_right(binary_part(s, 0, byte_size(s) - 3))

      :binary.last(s) in [?\s, ?\t, ?\n, ?\r] ->
        trim_right(binary_part(s, 0, byte_size(s) - 1))

      true ->
        s
    end
  end

  def digits?(s, min_len, max_len) do
    n = codepoint_count(s)
    n >= min_len and (max_len < 0 or n <= max_len) and all_digits?(s)
  end

  def all_digits?(s), do: s != "" and digits_only?(s)
  defp digits_only?(<<>>), do: true
  defp digits_only?(<<c, rest::binary>>) when c in ?0..?9, do: digits_only?(rest)
  defp digits_only?(_), do: false

  def safe_integer(s, def) do
    case Integer.parse(trim_space(s)) do
      {n, ""} -> n
      _ -> def
    end
  end

  def string_nth_field(s, index, delim) do
    parts = String.split(s, <<delim>>)
    Enum.at(parts, index, "")
  end

  def split_no_empty(s, pattern), do: String.split(s, pattern, trim: true)

  def split_once(s, delim) do
    case :binary.split(s, <<delim>>) do
      [one] -> {one, "", false}
      [a, b] -> {a, b, true}
    end
  end

  # ---------- HTML ----------
  def html_escape(s) do
    s
    |> String.replace("&", "&amp;")
    |> String.replace("\"", "&quot;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("'", "&#39;")
  end

  def html_unescape(s) do
    s
    |> String.replace("&lt;", "<")
    |> String.replace("&gt;", ">")
    |> String.replace("&quot;", "\"")
    |> String.replace("&#39;", "'")
    |> String.replace("&amp;", "&")
  end

  # 単純なタグ除去 (admin の題名の平文用)
  def strip_tags(s), do: strip_tags(s, false, [])
  defp strip_tags(<<>>, _in_tag, acc), do: acc |> Enum.reverse() |> IO.iodata_to_binary()
  defp strip_tags(<<c, rest::binary>>, in_tag, acc) do
    cond do
      c == ?< -> strip_tags(rest, true, acc)
      c == ?> -> strip_tags(rest, false, acc)
      in_tag -> strip_tags(rest, in_tag, acc)
      true -> strip_tags(rest, in_tag, [<<c>> | acc])
    end
  end

  @html_entities ["&amp;", "&quot;", "&lt;", "&gt;", "&#39;"]

  # 位置 (バイト列の先頭) から HTML エンティティが始まればそのバイト長
  def entity_len(bin) do
    Enum.find_value(@html_entities, 0, fn e ->
      if String.starts_with?(bin, e), do: byte_size(e), else: nil
    end)
  end

  # エンティティを1文字として数える (Python 版 html_chars_len)
  def html_chars_len(s), do: html_len(s, 0)
  defp html_len(<<>>, n), do: n

  defp html_len(bin, n) do
    case entity_len(bin) do
      0 ->
        case decode_rune(bin) do
          {_, size} ->
            <<_::binary-size(size), rest::binary>> = bin
            html_len(rest, n + 1)

          {:error, size} ->
            <<_::binary-size(size), rest::binary>> = bin
            html_len(rest, n + 1)
        end

      e ->
        <<_::binary-size(e), rest::binary>> = bin
        html_len(rest, n + 1)
    end
  end

  # エンティティを1文字として max_len 文字まで (Python 版 ccut)
  def ccut(s, max_len), do: ccut(s, max_len, 0)
  defp ccut(bin, max_len, n) when n >= max_len or bin == "", do: ""

  defp ccut(bin, max_len, n) do
    case entity_len(bin) do
      0 ->
        case decode_rune(bin) do
          {_, size} -> take_and_rest(bin, size, max_len, n)
          {:error, size} -> take_and_rest(bin, size, max_len, n)
        end

      e ->
        take_and_rest(bin, e, max_len, n)
    end
  end

  defp take_and_rest(bin, size, max_len, n) do
    <<head::binary-size(size), rest::binary>> = bin
    head <> ccut(rest, max_len, n + 1)
  end

  # Python 版 _INVISIBLE の文字を取り除く
  def strip_invisible(s), do: strip_inv(s, [])
  defp strip_inv(<<>>, acc), do: acc |> Enum.reverse() |> IO.iodata_to_binary()

  defp strip_inv(bin, acc) do
    case decode_rune(bin) do
      {cp, size} ->
        <<_::binary-size(size), rest::binary>> = bin
        if invisible?(cp), do: strip_inv(rest, acc), else: strip_inv(rest, [<<cp::utf8>> | acc])

      {:error, size} ->
        <<b::binary-size(size), rest::binary>> = bin
        strip_inv(rest, [b | acc])
    end
  end

  defp invisible?(cp) do
    (cp >= 0x0080 and cp <= 0x009F) or cp == 0x00AD or cp == 0x034F or cp == 0x061C or
      (cp >= 0x115F and cp <= 0x1160) or (cp >= 0x17B4 and cp <= 0x17B5) or
      (cp >= 0x180B and cp <= 0x180E) or cp == 0x200B or cp == 0x200C or
      (cp >= 0x200E and cp <= 0x200F) or (cp >= 0x2028 and cp <= 0x202E) or
      (cp >= 0x2060 and cp <= 0x206F) or cp == 0x3164 or cp == 0xFEFF or
      cp == 0xFFA0 or (cp >= 0xFFF9 and cp <= 0xFFFB)
  end

  # コードポイント単位の変換 (strip_invisible のような除去・置換用)
  def map_codepoints(s, fun) do
    s
    |> codepoints_list()
    |> Enum.map(fun)
    |> Enum.reject(&is_nil/1)
    |> IO.iodata_to_binary()
  end

  def codepoints_list(s), do: cp_list(s, [])
  defp cp_list(<<>>, acc), do: Enum.reverse(acc)

  defp cp_list(bin, acc) do
    case decode_rune(bin) do
      {cp, size} ->
        <<_::binary-size(size), rest::binary>> = bin
        cp_list(rest, [cp | acc])

      {:error, size} ->
        <<_::binary-size(size), rest::binary>> = bin
        cp_list(rest, [0xFFFD | acc])
    end
  end

  def codepoints_to_string(cps), do: cps |> Enum.map(&<<&1::utf8>>) |> IO.iodata_to_binary()

  # ---------- URL ----------
  defp hex_val(c) when c in ?0..?9, do: {c - ?0, true}
  defp hex_val(c) when c in ?a..?f, do: {c - ?a + 10, true}
  defp hex_val(c) when c in ?A..?F, do: {c - ?A + 10, true}
  defp hex_val(_), do: {0, false}

  def hex_val_byte(c), do: hex_val(c)

  # URL エンコードされたバイト列を、+ を空白として、UTF-8 で戻す
  def url_decode_bytes(bytes), do: bytes |> url_dec([]) |> IO.iodata_to_binary() |> utf8_decode()

  defp url_dec(<<>>, acc), do: Enum.reverse(acc)

  defp url_dec(<<c, rest::binary>>, acc) do
    cond do
      c == ?+ ->
        url_dec(rest, [" " | acc])

      c == ?% and byte_size(rest) >= 2 ->
        <<h, l, rest2::binary>> = rest
        {hi, ok1} = hex_val(h)
        {lo, ok2} = hex_val(l)

        if ok1 and ok2 do
          url_dec(rest2, [<<hi * 16 + lo>> | acc])
        else
          url_dec(rest, ["%" | acc])
        end

      true ->
        url_dec(rest, [<<c>> | acc])
    end
  end

  def url_decode(x), do: url_decode_bytes(x)

  # Python の urllib.parse.quote(s, safe='') 相当
  def url_encode(s), do: url_enc(s, [])
  defp url_enc(<<>>, acc), do: acc |> Enum.reverse() |> IO.iodata_to_binary()

  defp url_enc(<<c, rest::binary>>, acc) do
    if (c >= ?a and c <= ?z) or (c >= ?A and c <= ?Z) or (c >= ?0 and c <= ?9) or
         c in [?-, ?., ?_, ?~] do
      url_enc(rest, [<<c>> | acc])
    else
      hex = c |> Integer.to_string(16) |> String.pad_leading(2, "0")
      url_enc(rest, ["%" <> hex | acc])
    end
  end

  # ---------- 時刻 (JST 固定。OS の TZ に頼らない) ----------
  @unix_epoch_gregorian 62_167_219_200
  @jst_offset 9 * 3600
  @wdays ["月", "火", "水", "木", "金", "土", "日"]

  def epoch_now, do: System.system_time(:second)

  # エポック秒 -> {年, 月, 日, 時, 分, 秒, 曜日(月曜=0)}
  def epoch_to_jst(epoch) do
    greg = epoch + @jst_offset + @unix_epoch_gregorian
    {{y, m, d}, {hh, mm, ss}} = :calendar.gregorian_seconds_to_datetime(greg)
    wd = :calendar.day_of_the_week(y, m, d) - 1
    {y, m, d, hh, mm, ss, wd}
  end

  def jst_to_epoch(y, m, d, hh, mm, ss) do
    :calendar.datetime_to_gregorian_seconds({{y, m, d}, {hh, mm, ss}}) -
      @unix_epoch_gregorian - @jst_offset
  end

  defp pad2(n), do: n |> Integer.to_string() |> String.pad_leading(2, "0")

  # Python 版 date_str: 20yy年mm月dd日(曜)HH時MM分SS秒
  def format_jst_date(epoch) do
    {y, m, d, hh, mm, ss, wd} = epoch_to_jst(epoch)

    "#{y}年#{pad2(m)}月#{pad2(d)}日(#{Enum.at(@wdays, wd)})#{pad2(hh)}時#{pad2(mm)}分#{pad2(ss)}秒"
  end

  # スレッド番号: yyMMddHHmmss (JST)
  def format_res_number(epoch) do
    {y, m, d, hh, mm, ss, _} = epoch_to_jst(epoch)
    "#{pad2(rem(y, 100))}#{pad2(m)}#{pad2(d)}#{pad2(hh)}#{pad2(mm)}#{pad2(ss)}"
  end

  def format_admin_time(epoch) do
    {y, m, d, hh, mm, _, _} = epoch_to_jst(epoch)
    "#{y}-#{pad2(m)}-#{pad2(d)} #{pad2(hh)}:#{pad2(mm)}"
  end

  # ---------- ファイル ----------
  def file_regular?(path) do
    case File.stat(path) do
      {:ok, %File.Stat{type: :regular}} -> true
      _ -> false
    end
  end

  def dir_exists?(path) do
    case File.stat(path) do
      {:ok, %File.Stat{type: :directory}} -> true
      _ -> false
    end
  end

  def path_exists?(path), do: File.exists?(path)

  def ensure_dir(path) do
    File.mkdir(path)
    dir_exists?(path)
  end

  def file_size(path) do
    case File.stat(path, time: :posix) do
      {:ok, st} -> {st.size, true}
      _ -> {0, false}
    end
  end

  def file_mtime(path), do: file_time(path, :mtime)
  def file_ctime(path), do: file_time(path, :ctime)

  defp file_time(path, field) do
    case File.stat(path, time: :posix) do
      {:ok, st} -> {Map.fetch!(st, field), true}
      _ -> {0, false}
    end
  end

  def file_mode(path) do
    case File.stat(path) do
      {:ok, st} -> {Bitwise.band(st.mode, 0o777), true}
      _ -> {0, false}
    end
  end

  # File.chmod は Erlang の write_file_info 経由で mtime を現在時刻に
  # 戻してしまうことがあるため、変える前の mtime を保存して戻す
  # (他版の os.chmod は mtime を変えない)。
  def chmod_file(path, mode) do
    {mt, ok} = file_mtime(path)

    case File.chmod(path, mode) do
      :ok ->
        if ok and mt > 0, do: set_file_mtime(path, mt)
        :ok

      err ->
        err
    end
  end

  # 更新日時 (とアクセス日時) をエポック秒に設定する
  def set_file_mtime(path, epoch) do
    case File.touch(path, epoch) do
      :ok -> true
      _ -> false
    end
  end

  def rename_path(from, to), do: File.rename(from, to) == :ok
  def unlink_path(path), do: File.rm(path) == :ok

  def list_dir_names(path) do
    case File.ls(path) do
      {:ok, names} -> names
      _ -> []
    end
  end

  def read_file_octets(path), do: File.read(path)

  # UTF-8 で読む。失敗したら {"", false}
  def read_file_string(path) do
    case File.read(path) do
      {:ok, data} -> {utf8_decode(data), true}
      _ -> {"", false}
    end
  end

  # 行の一覧 (改行と末尾の CR を除く)。失敗したら {[], false}
  def read_file_lines(path) do
    case read_file_string(path) do
      {s, true} ->
        lines = String.split(s, "\n")
        lines = if List.last(lines) == "", do: Enum.drop(lines, -1), else: lines
        {Enum.map(lines, &String.trim_trailing(&1, "\r")), true}

      {_, false} ->
        {[], false}
    end
  end

  def write_file_string(path, content), do: File.write(path, content) == :ok
  def write_file_octets(path, octs), do: File.write(path, octs) == :ok

  def append_file_string(path, content), do: File.write(path, content, [:append]) == :ok

  # 一時ファイルに書いて rename する (Python 版の os.replace 相当)。既存ファイルのモードを保つ。
  def write_file_atomic(path, content) do
    tmp = path <> ".tmp" <> to_string(:os.getpid())
    mode = case file_mode(path) do {m, true} -> m; _ -> 0o644 end

    if write_file_string(tmp, content) do
      chmod_file(tmp, mode)

      case File.rename(tmp, path) do
        :ok ->
          true

        _ ->
          File.rm(tmp)
          false
      end
    else
      false
    end
  end

  def copy_file_simple(from, to) do
    case File.read(from) do
      {:ok, data} -> write_file_octets(to, data)
      _ -> false
    end
  end

  # ---------- IP ----------
  def ipv4_valid?(s) do
    parts = String.split(s, ".")

    length(parts) == 4 and
      Enum.all?(parts, fn p ->
        digits?(p, 1, 3) and not (String.length(p) > 1 and String.starts_with?(p, "0")) and
          safe_integer(p, 256) <= 255
      end)
  end

  # IPv6 文字列を 8 グループ (16bit 値) に展開する。壊れていれば nil。末尾の IPv4 表記にも対応。
  def ipv6_groups(s) do
    s = expand_ipv4_tail(s)

    valid_group = fn g ->
      n = byte_size(g)
      n >= 1 and n <= 4 and digits_hex?(g)
    end

    parse = fn gs ->
      vals =
        Enum.map(gs, fn g ->
          case Integer.parse(g, 16) do
            {v, ""} -> v
            _ -> nil
          end
        end)

      if Enum.any?(vals, &is_nil/1), do: nil, else: vals
    end

    case String.split(s, "::") do
      [left_s, right_s] ->
        left = if left_s == "", do: [], else: String.split(left_s, ":")
        right = if right_s == "", do: [], else: String.split(right_s, ":")

        cond do
          length(left) + length(right) > 7 -> nil
          not Enum.all?(left ++ right, valid_group) -> nil
          true ->
            zeros = List.duplicate(0, 8 - length(left) - length(right))
            out = (parse.(left) || []) ++ zeros ++ (parse.(right) || [])
            if length(out) == 8 and not is_nil(parse.(left)) and not is_nil(parse.(right)), do: out, else: nil
        end

      [one] ->
        if String.contains?(s, "::") do
          nil
        else
          gs = String.split(one, ":")

          if length(gs) == 8 and Enum.all?(gs, valid_group) do
            parse.(gs)
          else
            nil
          end
        end

      _ ->
        nil
    end
  end

  defp digits_hex?(<<>>), do: true

  defp digits_hex?(<<c, rest::binary>>) do
    case hex_val(c) do
      {_, true} -> digits_hex?(rest)
      _ -> false
    end
  end

  defp expand_ipv4_tail(s) do
    if String.contains?(s, ".") do
      case :binary.matches(s, ":") do
        [] ->
          s

        matches ->
          {idx, 1} = List.last(matches)
          v4 = binary_part(s, idx + 1, byte_size(s) - idx - 1)

          if ipv4_valid?(v4) do
            [a, b, c, d] = Enum.map(String.split(v4, "."), &safe_integer(&1, 0))

            binary_part(s, 0, idx + 1) <>
              Integer.to_string(a * 256 + b, 16) <> ":" <> Integer.to_string(c * 256 + d, 16)
          else
            s
          end
      end
    else
      s
    end
  end

  def ip_valid?(s) do
    s != "" and (ipv4_valid?(s) or (String.contains?(s, ":") and not is_nil(ipv6_groups(s))))
  end

  # Python 版 ip_unit: IPv6 は上位64bit の hex、IPv4 はそのまま
  def ip_unit(ip) do
    if String.contains?(ip, ":") do
      case ipv6_groups(ip) do
        nil ->
          ip

        gs ->
          gs
          |> Enum.take(4)
          |> Enum.map_join("", fn g ->
            g |> Integer.to_string(16) |> String.downcase() |> String.pad_leading(4, "0")
          end)
      end
    else
      ip
    end
  end

  # 位置 start (バイト) から数を読む (空白と符号を許す)。{値, true} か {0, false}。
  def parse_leading_int(s, start) do
    rest = binary_part(s, start, byte_size(s) - start)
    rest = String.trim_leading(rest, " ")
    rest = String.trim_leading(rest, "\t")
    {sign, rest} =
      case rest do
        "+" <> r -> {1, r}
        "-" <> r -> {-1, r}
        _ -> {1, rest}
      end

    digits = take_leading_digits(rest)

    cond do
      digits == "" ->
        {0, false}

      String.length(digits) > 9 ->
        {sign * 1_073_741_824, true}

      true ->
        {sign * safe_integer(digits, 0), true}
    end
  end

  defp take_leading_digits(s), do: take_leading_digits(s, [])
  defp take_leading_digits(<<c, rest::binary>>, acc) when c in ?0..?9, do: take_leading_digits(rest, [c | acc])
  defp take_leading_digits(_, acc), do: acc |> Enum.reverse() |> List.to_string()

  def getenv_default(name, def) do
    case System.get_env(name) do
      nil -> def
      v -> v
    end
  end
end
