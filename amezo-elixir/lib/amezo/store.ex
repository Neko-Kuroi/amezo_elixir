defmodule Amezo.Store do
  @moduledoc """
  ファイル形式の層: blist / cap / delpass / 過去ログ / 認証キー / スレッドの題名など。
  読み取りはプロセスを経由しない。keys.txt の書き換えとスレッドの鍵操作は、
  呼び出し側が Board.run/2 で直列化している前提で、ここでは直接書く。
  """
  alias Amezo.{Config, Crypto, Exit, Sys, Util}

  # ---------- 板 ----------
  def blist_lines do
    {lines, _} = Util.read_file_lines(Config.app_path("blist.txt"))
    lines
  end

  def is_board(folder) do
    Enum.any?(blist_lines(), fn line ->
      line != "" and Util.string_nth_field(line, 0, ?,) == folder
    end)
  end

  # (背景色, タイトル)
  def board_info(folder) do
    Enum.find_value(blist_lines(), {"", ""}, fn line ->
      if line == "" do
        nil
      else
        parts = String.split(line, ",")

        if hd(parts) == folder do
          {Enum.at(parts, 1, ""), Enum.at(parts, 2, "")}
        else
          nil
        end
      end
    end)
  end

  def board_folders do
    Enum.flat_map(blist_lines(), fn line ->
      case Util.string_nth_field(line, 0, ?,) do
        "" -> []
        name -> [name]
      end
    end)
  end

  # ---------- delpass / cap ----------
  def load_delcrypt do
    case Util.read_file_string(Config.app_path(Config.delcrypt_file())) do
      {s, true} -> Util.trim_space(s)
      _ -> ""
    end
  end

  def is_cap(name_escaped, password) do
    if password == "" do
      false
    else
      {lines, _} = Util.read_file_lines(Config.app_path(Config.cap_file()))

      Enum.any?(lines, fn line ->
        if line == "" or String.starts_with?(line, "#") or not String.contains?(line, ",") do
          false
        else
          pos = line |> :binary.matches(",") |> List.last() |> elem(0)
          cap_name = binary_part(line, 0, pos)
          stored = binary_part(line, pos + 1, byte_size(line) - pos - 1)

          Util.html_escape(Amezo.Core.remove_name_spaces(cap_name)) == name_escaped and
            Crypto.verify_hash(password, stored)
        end
      end)
    end
  end

  # ---------- 過去ログ ----------
  # o数字.html の実体パス (平文優先、無ければ .gz)。無ければ ""
  def archived_path(folder, name) do
    p = Config.app_path([folder, name])

    cond do
      Util.file_regular?(p) -> p
      Util.file_regular?(p <> ".gz") -> p <> ".gz"
      true -> ""
    end
  end

  def archived_exists(folder, res) do
    Util.all_digits?(res) and archived_path(folder, "o" <> res <> ".html") != ""
  end

  def thread_missing(folder, res, verb) do
    if archived_exists(folder, res) do
      Exit.page_error("このスレッドは過去ログになったため#{verb}できません.")
    else
      Exit.page_error("スレッドがありません.")
    end
  end

  # ---------- スレッドの読み取り ----------
  def first_line(s) do
    case :binary.match(s, "\n") do
      {idx, 1} -> binary_part(s, 0, idx)
      :nomatch -> s
    end
  end

  # 最初の <tag>...</tag> の中身。無ければ {"", false}
  def extract_tag_content(s, tag) do
    open = "<" <> tag <> ">"
    close = "</" <> tag <> ">"

    case :binary.match(s, open) do
      :nomatch ->
        {"", false}

      {a, olen} ->
        rest = binary_part(s, a + olen, byte_size(s) - a - olen)

        case :binary.match(rest, close) do
          :nomatch -> {"", false}
          {b, _} -> {binary_part(rest, 0, b), true}
        end
    end
  end

  # <b>([^<]*)</b> 相当: 最初の <b> から < まで
  def extract_first_b(s) do
    case :binary.match(s, "<b>") do
      :nomatch ->
        {"", false}

      {a, 3} ->
        rest = binary_part(s, a + 3, byte_size(s) - a - 3)

        case :binary.match(rest, "<") do
          :nomatch -> {"", false}
          {b, 1} -> {binary_part(rest, 0, b), true}
        end
    end
  end

  # スレッドファイル (または .gz) の1行目から <b>題名</b> を取る。読めなければ ""
  def read_thread_title(path) do
    first =
      cond do
        String.ends_with?(path, ".gz") ->
          case Sys.gunzip_to_string(path) do
            {s, true} -> first_line(s)
            _ -> nil
          end

        true ->
          case Util.read_file_string(path) do
            {s, true} -> first_line(s)
            _ -> nil
          end
      end

    if first do
      case extract_tag_content(first, "b") do
        {v, true} -> v
        _ -> ""
      end
    else
      ""
    end
  end

  def count_newlines_in_file(path) do
    case File.read(path) do
      {:ok, data} -> data |> :binary.bin_to_list() |> Enum.count(&(&1 == ?\n))
      _ -> 0
    end
  end

  # ---------- 認証キー ----------
  # 入力キーを正規形 (大文字24文字) にする。形が違えば ""
  def key_normalize(s) do
    chars =
      s
      |> Util.codepoints_list()
      |> Enum.filter(fn c ->
        (c >= ?a and c <= ?z) or (c >= ?A and c <= ?Z) or (c >= ?2 and c <= ?7)
      end)
      |> Enum.map(fn c -> if c >= ?a and c <= ?z, do: c - 32, else: c end)

    if length(chars) == 24, do: Util.codepoints_to_string(chars), else: ""
  end

  def key_display(canon) do
    canon
    |> String.graphemes()
    |> Enum.chunk_every(4)
    |> Enum.map_join("-", &Enum.join/1)
  end

  def key_hash(canon) do
    Crypto.hmac_sha256_hex(Amezo.Core.key_secret_key(), Config.key_ctx() <> canon)
  end

  def parse_key_row(line) do
    case String.split(line, "\t") do
      [id, label, hash, scope, created_s, status] ->
        %{
          id: id,
          label: label,
          hash: hash,
          scope: scope,
          created: parse_int_prefix(created_s),
          status: status
        }

      _ ->
        nil
    end
  end

  # 先頭の (符号つき) 整数。読めなければ 0
  def parse_int_prefix(s) do
    {sign, rest} =
      case s do
        "-" <> r -> {-1, r}
        _ -> {1, s}
      end

    digits = take_digits(rest)

    if digits == "" do
      0
    else
      sign * Util.safe_integer(digits, 0)
    end
  end

  defp take_digits(s), do: take_digits(s, [])
  defp take_digits(<<c, rest::binary>>, acc) when c in ?0..?9, do: take_digits(rest, [c | acc])
  defp take_digits(_, acc), do: acc |> Enum.reverse() |> List.to_string()

  def keys_load(folder) do
    {lines, _} = Util.read_file_lines(Config.app_path([folder, Config.keys_file()]))

    Enum.flat_map(lines, fn line ->
      case parse_key_row(line) do
        nil -> []
        row -> [row]
      end
    end)
  end

  def key_find_row(folder, kid) do
    {lines, _} = Util.read_file_lines(Config.app_path([folder, Config.keys_file()]))
    prefix = kid <> "\t"

    Enum.find_value(lines, fn line ->
      if String.starts_with?(line, prefix), do: parse_key_row(line), else: nil
    end)
  end

  def key_verify(folder, res, input_key) do
    canon = key_normalize(input_key)

    if canon == "" do
      false
    else
      row = key_find_row(folder, String.slice(canon, 0, 4))

      not is_nil(row) and row.status == "active" and
        Crypto.constant_time_string_equal(row.hash, key_hash(canon)) and
        (row.scope == "*" or row.scope == res)
    end
  end

  # keys.txt を fn(全行) の結果で書き直す。呼び出し側が Board.run で直列化していること。失敗したら false。
  def keys_update(folder, fun) do
    rows = fun.(keys_load(folder))
    path = Config.app_path([folder, Config.keys_file()])
    tmp = path <> ".tmp" <> to_string(:os.getpid())

    content =
      Enum.map_join(rows, "", fn r ->
        "#{r.id}\t#{r.label}\t#{r.hash}\t#{r.scope}\t#{r.created}\t#{r.status}\n"
      end)

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

  # {ID, 表示用キー} を返す。失敗したら {"", ""}
  def key_issue(folder, label, scope) do
    label =
      label
      |> String.replace(~r/[\x00-\x1F\x7F]/, " ")
      |> Util.trim_space()
      |> Util.cp_take(40)

    label = if label == "", do: "(無題)", else: label

    if scope != "*" and not Util.digits?(scope, 1, 20) do
      {"", ""}
    else
      ref = make_ref()

      ok =
        keys_update(folder, fn rows ->
          used = MapSet.new(rows, & &1.id)
          canon = fresh_canon(used)
          Process.put(ref, {String.slice(canon, 0, 4), key_display(canon)})

          rows ++
            [
              %{
                id: String.slice(canon, 0, 4),
                label: label,
                hash: key_hash(canon),
                scope: scope,
                created: Util.epoch_now(),
                status: "active"
              }
            ]
        end)

      if ok, do: Process.get(ref, {"", ""}), else: {"", ""}
    end
  end

  defp fresh_canon(used) do
    canon = Crypto.base32_encode(Crypto.random_octets(15))
    if MapSet.member?(used, String.slice(canon, 0, 4)), do: fresh_canon(used), else: canon
  end

  def key_revoke(folder, kid) do
    ref = make_ref()

    ok =
      keys_update(folder, fn rows ->
        Enum.map(rows, fn r ->
          if r.id == kid and r.status == "active" do
            Process.put(ref, true)
            %{r | status: "revoked"}
          else
            r
          end
        end)
      end)

    ok and Process.get(ref, false)
  end

  # ---------- スレッドの鍵 ----------
  def thread_is_locked(folder, res) do
    Util.file_regular?(Config.app_path([folder, res <> ".lock"]))
  end

  # 呼び出し側が Board.run で直列化していること
  def thread_set_lock(folder, res, lock) do
    path = Config.app_path([folder, res <> ".html"])

    if not Util.file_regular?(path) do
      false
    else
      case Util.read_file_string(path) do
        {data, true} ->
          footer =
            case last_index_of(data, "\n<form") do
              nil -> byte_size(data)
              idx -> idx + 1
            end

          content =
            binary_part(data, 0, footer) <>
              Amezo.Core.reply_form(res, "", lock) <> "</body></html>\n"

          if Util.write_file_string(path, content) do
            lockfile = Config.app_path([folder, res <> ".lock"])

            if lock do
              Util.write_file_string(lockfile, "")
            else
              File.rm(lockfile)
            end

            true
          else
            false
          end

        _ ->
          false
      end
    end
  end

  defp last_index_of(s, pat) do
    case :binary.matches(s, pat) do
      [] -> nil
      matches -> matches |> List.last() |> elem(0)
    end
  end
end
