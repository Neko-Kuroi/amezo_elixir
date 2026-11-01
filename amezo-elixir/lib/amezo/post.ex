defmodule Amezo.Post do
  @moduledoc """
  amezo.py のメイン処理 (投稿の受付とレス表示)。
  スレッドファイルへの書き込みは Board.run/2 で板プロセスに直列化する。
  """
  alias Amezo.{Board, Config, Core, Exit, Regen, Req, Store, Util}

  # ---------- フォーム解析 ----------
  def form_get(form, key) do
    Enum.find_value(form, "", fn {k, v} -> if k == key, do: v, else: nil end)
  end

  def form_has(form, key), do: Enum.any?(form, fn {k, _} -> k == key end)

  # QUERY_STRING をリストにする (値は url-decode 済み、キーはそのまま)。重複キーは最初のもの。
  def parse_params(s) do
    if s == "" do
      []
    else
      s
      |> String.split("&")
      |> Enum.reject(&(&1 == ""))
      |> Enum.map(fn pair ->
        {k, v, _} = Util.split_once(pair, ?=)
        {k, Util.url_decode(v)}
      end)
    end
  end

  # POST 本体を {リスト, trip用パスワード} にする。Python 版 main の前処理と同じ
  def parse_form_body(octs) do
    if octs == "" or is_nil(octs) do
      {[], ""}
    else
      {form_rev, trip_pw} =
        octs
        |> :binary.split("&", [:global])
        |> Enum.reduce({[], ""}, fn pair, {form, trip_pw} ->
          case :binary.split(pair, "=") do
            [_no_eq] ->
              {form, trip_pw}

            [kbin, vbin] ->
              key = Util.utf8_decode(kbin)
              value = Util.url_decode_bytes(vbin)
              value = Util.strip_invisible(value)

              {value, trip_pw} =
                if key == "name" do
                  case :binary.match(value, "#") do
                    {p, 1} ->
                      pw =
                        value
                        |> binary_part(p + 1, byte_size(value) - p - 1)
                        |> remove_control_chars()

                      {binary_part(value, 0, p), pw}

                    :nomatch ->
                      {value, trip_pw}
                  end
                else
                  {value, trip_pw}
                end

              value = Util.html_escape(value)
              value = value |> String.replace("\r\n", "\r") |> String.replace("\n", "\r")
              value = if key == "comm", do: String.replace(value, "\r", "<br>"), else: value
              value = remove_control_chars(value)
              {[{key, value} | form], trip_pw}
          end
        end)

      {Enum.reverse(form_rev), trip_pw}
    end
  end

  defp remove_control_chars(s) do
    s
    |> Util.codepoints_list()
    |> Enum.reject(fn c -> c <= 0x1F end)
    |> Util.codepoints_to_string()
  end

  def count_occurrences(needle, s), do: length(:binary.matches(s, needle))

  # &gt;(&gt;)+ -> &gt; 相当
  def collapse_gt(s), do: collapse_gt(s, [])
  defp collapse_gt(<<>>, acc), do: acc |> Enum.reverse() |> IO.iodata_to_binary()

  defp collapse_gt(s, acc) do
    if String.starts_with?(s, "&gt;") do
      collapse_gt(skip_gts(s), ["&gt;" | acc])
    else
      <<c, rest::binary>> = s
      collapse_gt(rest, [<<c>> | acc])
    end
  end

  defp skip_gts(s) do
    if String.starts_with?(s, "&gt;") do
      skip_gts(binary_part(s, 4, byte_size(s) - 4))
    else
      s
    end
  end

  defp remove_ng(word, s), do: String.replace(s, Util.html_escape(word), "")

  # Board.run の結果をほどく (bail は投げ直す)
  def board!(folder, fun) do
    case Board.run(folder, fun) do
      {:ok, v} -> v
      {:bail, resp} -> Exit.bail(resp)
      {:raised, e} -> raise e
    end
  end

  # ---------- レス表示 ----------
  def res_view(folder, form) do
    res = form_get(form, "res")

    if not Util.all_digits?(res) do
      Exit.page_error("不正なスレッド指定です")
    end

    from_idx = max(Util.safe_integer(form_get(form, "from"), 1), 1)
    file_path = Config.app_path([folder, res <> ".html"])

    if not Util.path_exists?(file_path) do
      Store.thread_missing(folder, res, "表示")
    end

    {lines, _} = Util.read_file_lines(file_path)
    fol_tag = "<input type=\"hidden\" name=\"folder\" value=\"" <> Util.html_escape(folder) <> "\">"

    fixj = fn line -> String.replace(line, "href=\"../jump.cgi?", "href=\"jump.cgi?") end

    form_line = fn line ->
      line
      |> String.replace("action=\"../", "action=\"")
      |> String.replace("</form>", fol_tag <> "</form>")
    end

    fixbase = fn line ->
      line
      |> String.replace("href=\"../style.css\"", "href=\"style.css\"")
      |> String.replace("src=\"../hide.js\"", "src=\"hide.js\"")
      |> fixj.()
    end

    # <dl> か <dt> を含む行まで (置換して) 出す
    {out, rest} = take_until_dl(lines, fixbase)
    {out, rest, matched, footer} = find_from_res(rest, from_idx, fixj, out)

    out =
      if not matched and footer != "" do
        out ++ [form_line.(footer)]
      else
        out
      end

    out =
      Enum.reduce(rest, out, fn line, acc ->
        rendered =
          if String.contains?(line, "</form>") do
            form_line.(line)
          else
            fixj.(line)
          end

        acc ++ [rendered]
      end)

    Exit.bail(Exit.html_header_response(Enum.map_join(out, "", fn l -> l <> "\n" end), 200))
  end

  defp take_until_dl(lines, fixbase), do: take_until_dl(lines, fixbase, [])
  defp take_until_dl([], _fix, acc), do: {Enum.reverse(acc), []}

  defp take_until_dl([line | rest], fixbase, acc) do
    acc = [fixbase.(line) | acc]

    if String.contains?(line, "<dl>") or String.contains?(line, "<dt>") do
      {Enum.reverse(acc), rest}
    else
      take_until_dl(rest, fixbase, acc)
    end
  end

  defp find_from_res(lines, from_idx, fixj, out), do: find_from_res(lines, from_idx, fixj, out, "")
  defp find_from_res([], _from, _fixj, out, footer), do: {out, [], false, footer}

  defp find_from_res([line | rest], from_idx, fixj, out, footer) do
    footer = if String.starts_with?(line, "<form"), do: line, else: footer

    case :binary.match(line, "<dt>") do
      :nomatch ->
        find_from_res(rest, from_idx, fixj, out, footer)

      {dt, 4} ->
        case Util.parse_leading_int(line, dt + 4) do
          {num, true} when num >= from_idx ->
            {out ++ [fixj.(line)], rest, true, footer}

          _ ->
            find_from_res(rest, from_between(from_idx, line), fixj, out, footer)
        end
    end
  end

  # find_from_res の継続 (読みにくさ回避のための小さな委譲)
  defp from_between(from_idx, _line), do: from_idx

  # 前のレス行から {名前, 本文} を取る。取れなければ :error
  def parse_prev_post(line) do
    with {b1, _} <- find_str(line, "投稿者：<font"),
         {bs, _} <- find_str_from(line, "><b>", b1),
         {be, _} <- find_str_from(line, " </b>", bs),
         {dd, _} <- find_str_from(line, "<dd>", be),
         {de, _} <- find_str_from(line, " </dl>", dd) do
      name = binary_part(line, bs + 4, be - (bs + 4))
      body = binary_part(line, dd + 4, de - (dd + 4))
      {name, body, true}
    else
      _ -> {"", "", false}
    end
  end

  defp find_str(s, pat) do
    case :binary.match(s, pat) do
      :nomatch -> :error
      {i, l} -> {i, l}
    end
  end

  defp find_str_from(s, pat, from) do
    rest = binary_part(s, from, byte_size(s) - from)

    case :binary.match(rest, pat) do
      :nomatch -> :error
      {i, l} -> {from + i, l}
    end
  end

  # ---------- メイン ----------
  def handle_amezo(%Req{} = req) do
    Exit.run_handler(fn -> amezo_main(req) end)
  end

  def amezo_main(%Req{} = req) do
    body = req.body || ""

    if byte_size(body) > Config.max_post_bytes() do
      Exit.page_error("投稿内容が大きすぎます")
    end

    query_params = parse_params(req.query_string)
    {form, trip_pw} = parse_form_body(body)

    folder = resolve_folder(form, query_params, req)

    if folder == "" do
      Exit.page_error("板名が判定できません。")
    end

    if String.contains?(folder, "/") or String.contains?(folder, "..") or
         not Store.is_board(folder) do
      Exit.page_error("板名が不正です")
    end

    name = form_get(form, "name")
    mail = form_get(form, "mail")
    comm = form_get(form, "comm")
    subj = form_get(form, "subj")
    res = form_get(form, "res")

    if res != "" and not Util.all_digits?(res) do
      Exit.page_error("不正なスレッド指定です")
    end

    if form_has(form, "sub") and form_get(form, "sub") != "" do
      res_view(folder, form)
    end

    page_raw = if form_has(form, "page"), do: form_get(form, "page"), else: form_get(query_params, "page")
    next_raw = if form_has(form, "next"), do: form_get(form, "next"), else: form_get(query_params, "next")

    page =
      cond do
        Util.digits?(page_raw, 1, 6) ->
          Util.safe_integer(page_raw, 1)

        Util.digits?(next_raw, 1, 6) ->
          n = max(Util.safe_integer(next_raw, 1), 1)
          1 + div(n - 1, Config.per_page())

        true ->
          1
      end

    page = Regen.page_clamp(folder, page)

    reload_flag = (name == subj and name == comm) or (name == "" and subj == "" and comm == "")

    if count_occurrences("<br>", comm) > Config.comm_lines_max() do
      Exit.page_error("改行が多すぎます")
    end

    if Util.html_chars_len(String.replace(comm, "<br>", "\n")) > Config.comm_max() do
      Exit.page_error("コメントが長すぎます")
    end

    if Util.html_chars_len(mail) > Config.mail_max() do
      Exit.page_error("メールが長すぎます")
    end

    subj = remove_subj_spaces(subj)

    if Util.html_chars_len(subj) > Config.subj_max() do
      Exit.page_error("題名が長すぎます")
    end

    name =
      name
      |> String.replace(Config.trip_mark(), "◇")
      |> String.replace(Config.cap_mark(), "☆")
      |> Core.remove_name_spaces()
      |> Util.ccut(Config.name_max())

    comm = collapse_gt(comm)

    {name, comm, mail, subj, reload_flag} = apply_ng(name, comm, mail, subj, reload_flag)

    if page == 1 and not reload_flag do
      do_post(req, folder, name, mail, comm, subj, res, trip_pw, form)
    end

    index_name =
      board!(folder, fn -> Regen.regen_index(folder, page, reload_flag, true) end)
      |> elem(0)

    Exit.redirect_response(folder, index_name)
  end

  defp resolve_folder(form, query_params, req) do
    folder = form_get(form, "folder")
    folder = if folder == "", do: form_get(query_params, "folder"), else: folder

    if folder != "" do
      folder
    else
      referer =
        req
        |> Req.header("Referer")
        |> Util.url_decode()
        |> String.replace("://www.", "://")

      case :binary.match(referer, "://") do
        :nomatch ->
          ""

        {p, 3} ->
          rest = binary_part(referer, p + 3, byte_size(referer) - p - 3)

          case :binary.match(rest, "/") do
            :nomatch ->
              ""

            {slash, 1} ->
              after_slash = binary_part(rest, slash + 1, byte_size(rest) - slash - 1)

              case :binary.match(after_slash, "/") do
                :nomatch -> ""
                {slash2, 1} -> binary_part(after_slash, 0, slash2)
              end
          end
      end
    end
  end

  defp remove_subj_spaces(subj) do
    subj
    |> Util.codepoints_list()
    |> Enum.reject(fn c -> c == ?\s or c == 0x3000 or c == 0xFF3F end)
    |> Util.codepoints_to_string()
  end

  defp apply_ng(name, comm, mail, subj, reload_flag) do
    if not Util.path_exists?(Config.app_path("ng.txt")) do
      {name, comm, mail, subj, reload_flag}
    else
      {lines, _} = Util.read_file_lines(Config.app_path("ng.txt"))

      Enum.reduce(lines, {name, comm, mail, subj, reload_flag}, fn line, {name, comm, mail, subj, reload_flag} ->
        if line == "" do
          {name, comm, mail, subj, reload_flag}
        else
          parts = String.split(line, ",")
          ng = hd(parts)
          opt = Enum.at(parts, 1, "")

          cond do
            ng == "" ->
              {name, comm, mail, subj, reload_flag}

            opt == "n" ->
              if String.contains?(name, Util.html_escape(ng)),
                do: {name, comm, mail, subj, true},
                else: {name, comm, mail, subj, reload_flag}

            opt == "c" ->
              if String.contains?(comm, Util.html_escape(ng)),
                do: {name, comm, mail, subj, true},
                else: {name, comm, mail, subj, reload_flag}

            true ->
              {remove_ng(ng, name), remove_ng(ng, comm), remove_ng(ng, mail), remove_ng(ng, subj), reload_flag}
          end
        end
      end)
    end
  end

  defp do_post(req, folder, name, mail, comm, subj, res, trip_pw, form) do
    cap_ok = Core.is_cap(name, trip_pw)

    name =
      if cap_ok do
        name
      else
        String.replace(name, Util.html_escape(Config.admin_name()), "＃" <> Config.admin_name())
      end

    subj = if res != "", do: "", else: subj

    cond do
      name == "" -> Exit.page_error("投稿者を記入してください")
      comm == "" -> Exit.page_error("コメントが入力されていません")
      res == "" and subj == "" -> Exit.page_error("題名が入力されていません")
      true -> :ok
    end

    if Core.post_interval_left(folder) > 0 do
      left = Core.post_interval_left(folder)
      Exit.page_error("連投を検知しました。あと #{left} 秒ほど待ってから投稿してください")
    end

    ip = Core.client_ip(req)

    if subj != "" do
      Core.check_global_ip(req)
    end

    comm = Core.linkify_urls(comm, Config.jump_enabled())

    {name, trip} =
      if cap_ok do
        {name <> Config.cap_mark(), ""}
      else
        trip = Core.make_trip(trip_pw)

        if trip != "" do
          {name <> Config.trip_mark() <> trip, trip}
        else
          {name, ""}
        end
      end

    name =
      if mail != "" do
        "<a href=\"mailto:" <> mail <> " \">" <> name <> " </a>"
      else
        name
      end

    now = Util.epoch_now()
    post_id = Core.make_id(ip, folder, now)
    date_str = Util.format_jst_date(now)
    res = if res == "", do: Util.format_res_number(now), else: res

    board!(folder, fn ->
      post_write(folder, res, subj, name, comm, trip, post_id, date_str, form)
    end)
  end

  # スレッドファイルへの書き込み (新規作成 / 返信)。Board.run の中で呼ばれる。
  def post_write(folder, res, subj, name, comm, trip, post_id, date_str, form) do
    new_thread = subj != ""

    res =
      if new_thread do
        create_thread_file(folder, res, 0)
      else
        res
      end

    file_path = Config.app_path([folder, res <> ".html"])

    if not Util.path_exists?(file_path) do
      Store.thread_missing(folder, res, "返信")
    end

    if not write_post_under_lock(folder, res, subj, name, comm, trip, post_id, date_str, form, file_path, new_thread) do
      Exit.page_error("スレッドがありません.")
    end
  end

  defp create_thread_file(folder, res, try_count) do
    file_path = Config.app_path([folder, res <> ".html"])

    created =
      not Util.path_exists?(Config.app_path([folder, "x" <> res <> ".html"])) and
        not Store.archived_exists(folder, res) and
        exclusive_create(file_path)

    cond do
      created ->
        Util.write_file_string(file_path, "")
        res

      try_count >= 30 ->
        Exit.page_error("スレッドを作成できません.")

      true ->
        n = Util.safe_integer(res, 0)
        create_thread_file(folder, Integer.to_string(n + 1), try_count + 1)
    end
  end

  defp exclusive_create(path) do
    case File.open(path, [:write, :exclusive]) do
      {:ok, f} -> File.close(f); true
      _ -> false
    end
  end

  defp write_post_under_lock(folder, res, subj, name, comm, trip, post_id, date_str, form, file_path, new_thread) do
    locked = not new_thread and Store.thread_is_locked(folder, res)

    if locked do
      given = form_get(form, "key")

      cond do
        given == "" ->
          Exit.page_error("このスレッドは認証キーが必要です。ページを再読み込みして、認証キーの欄に入力してください。")

        not Store.key_verify(folder, res, given) ->
          Exit.page_error("認証キーが正しくありません。")

        true ->
          :ok
      end
    end

    {lines, _} = Util.read_file_lines(file_path)

    {cnt, prev, pos_lines} =
      Enum.reduce_while(lines, {0, "", 0}, fn line, {cnt0, prev0, pos} ->
        case :binary.match(line, "<dt>") do
          :nomatch ->
            {:halt, {cnt0, prev0, pos}}

          {dt, 4} ->
            case Util.parse_leading_int(line, dt + 4) do
              {num, true} -> {:cont, {num, line, pos + 1}}
              _ -> {:halt, {cnt0, prev0, pos}}
            end
        end
      end)

    cnt = cnt + 1

    case parse_prev_post(prev) do
      {pname, pcomm, true} when pname == name and pcomm == comm ->
        Exit.page_error("二重カキコです.")

      _ ->
        :ok
    end

    {subj1, subj2} =
      if new_thread do
        {"<html><head><meta charset=\"UTF-8\"><meta name=\"viewport\" content=\"width=device-width, initial-scale=1\"><title>" <>
           subj <> " </title><link rel=\"stylesheet\" href=\"../style.css\">" <> Config.script_tag() <> "</head><body>",
         "<font size=+2 color=red><b>" <> subj <> " </b></font>"}
      else
        {"", ""}
      end

    meta = "<font size=-1 class=\"meta\" data-id=\"" <> post_id <> "\""
    meta = if trip != "", do: meta <> " data-trip=\"" <> trip <> "\"", else: meta
    meta = meta <> ">"

    new_line =
      subj1 <> "<dl><dt>" <> Integer.to_string(cnt) <> subj2 <>
        "投稿者：<font color=forestgreen><b>" <> name <> " </b></font>" <>
        meta <> "　投稿日：" <> date_str <> " ID:" <> post_id <> "</font><br><dd>" <> comm <> " </dl>"

    content =
      (lines |> Enum.take(pos_lines) |> Enum.map_join("", fn l -> l <> "\n" end)) <>
        new_line <> "\n" <>
        Core.reply_form(res, "", locked) <> "</body></html>\n"

    Util.write_file_string(file_path, content)
    Core.touch_lasttime_board()
    true
  end
end
