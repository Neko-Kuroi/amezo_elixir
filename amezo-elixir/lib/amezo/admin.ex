defmodule Amezo.Admin do
  @moduledoc """
  管理画面 (Python 版 admin.py)。
  変更操作は Board.run/2 で板プロセスに直列化する。日時の解釈は Python 版の
  DATE_RE に合わせる (Go/Lisp 版の「単位の直前の数字」方式は 投稿日 の 日 に
  引っかかって常に失敗する癖があったため、仕様の正本に合わせて直してある)。
  """
  alias Amezo.{Config, Core, Counters, Crypto, Exit, Post, Regen, Req, Resp, Store, Util}

  @admin_max_body 65_536
  @admin_list_limit 100
  @admin_body_preview 60
  @admin_style """
  <style>
  body { font-family: sans-serif; margin: 12px; }
  table { border-collapse: collapse; }
  th, td { border: 1px solid #999; padding: 4px 8px; vertical-align: top; }
  td.body { max-width: 32em; word-break: break-all; }
  form.inline { display: inline; }
  .msg { padding: 6px 10px; border: 1px solid #c33; margin: 8px 0; }
  .msg.ok { border-color: #393; }
  .keybox { border: 2px solid #c60; padding: 10px 14px; margin: 10px 0; background: #fff8e8; }
  .keybox code { font-size: 1.3em; letter-spacing: 0.05em; user-select: all; }
  button { padding: 4px 12px; }
  </style>
  """

  @date_re ~r/(\d{4})年(\d{2})月(\d{2})日\([^)]+\)(\d{2})時(\d{2})分(\d{2})秒/

  # ---------- 画面の部品 ----------
  def admin_page(title, body) do
    Exit.bail(%Resp{
      status: 200,
      headers: [
        {"Content-Type", "text/html; charset=UTF-8"},
        {"Cache-Control", "no-store"},
        {"X-Robots-Tag", "noindex"}
      ],
      body:
        "<!DOCTYPE html>\n<html lang=\"ja\"><head><meta charset=\"UTF-8\">" <>
          "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">" <>
          "<meta name=\"robots\" content=\"noindex\"><title>" <> Util.html_escape(title) <>
          "</title>" <> @admin_style <> "</head><body>\n<h2>" <> Util.html_escape(title) <>
          "</h2>\n" <> body <> "\n</body></html>\n"
    })
  end

  def admin_msg("", _ok), do: ""

  def admin_msg(message, ok) do
    cls = if ok, do: "msg ok", else: "msg"
    "<div class=\"" <> cls <> "\">" <> Util.html_escape(message) <> "</div>"
  end

  def admin_hidden(pw, fields \\ []) do
    out = "<input type=\"hidden\" name=\"adminpass\" value=\"" <> Util.html_escape(pw) <> "\">"

    Enum.reduce(fields, out, fn {k, v}, acc ->
      acc <> "<input type=\"hidden\" name=\"" <> Util.html_escape(k) <> "\" value=\"" <> Util.html_escape(v) <> "\">"
    end)
  end

  def admin_btn(pw, label, confirm, act, folder, res, id) do
    fields =
      []
      |> add_field("act", act)
      |> add_field("folder", folder)
      |> add_field("res", res)
      |> add_field("id", id)

    onclick =
      if confirm != "" do
        " onclick=\"return confirm('" <> Util.html_escape(confirm) <> "')\""
      else
        ""
      end

    "<form method=\"post\" action=\"admin.cgi\" class=\"inline\">" <>
      admin_hidden(pw, fields) <> "<button type=\"submit\"" <> onclick <> ">" <>
      Util.html_escape(label) <> "</button></form>"
  end

  defp add_field(fields, _k, ""), do: fields
  defp add_field(fields, k, v), do: fields ++ [{k, v}]

  def admin_nav(pw, folder) do
    s = admin_btn(pw, "板一覧", "", "boards", "", "", "")

    s =
      if folder != "" do
        s <> " " <> admin_btn(pw, "「#{folder}」のスレッド一覧", "", "threads", folder, "", "")
      else
        s
      end

    "<p>" <> s <> "</p>"
  end

  def admin_fatal(pw, message) do
    admin_page("エラー", admin_msg(message, false) <> admin_nav(pw, ""))
  end

  def admin_login_page(message) do
    admin_page(
      "管理画面",
      admin_msg(message, false) <>
        "<form method=\"post\" action=\"admin.cgi\"><input type=\"hidden\" name=\"act\" value=\"boards\">管理用パスワード <input type=\"password\" name=\"adminpass\" autocomplete=\"current-password\"> <button type=\"submit\">ログイン</button></form>"
    )
  end

  # ---------- 認証 (失敗回数の制限つき) ----------
  def admin_authenticate(pw, req) do
    ip = Core.client_ip(req)
    unit = if ip == "", do: "unknown", else: ip
    who = binary_part(Crypto.hmac_sha256_hex(Core.id_key(), "adm:" <> Util.ip_unit(unit)), 0, 24)

    if Counters.admin_blocked?(who) do
      admin_page(
        "管理画面",
        admin_msg("失敗が続いたため、しばらく受け付けません。時間をおいてやり直してください。", false)
      )
    end

    delcrypt = Store.load_delcrypt()

    if delcrypt == "" do
      admin_page(
        "管理画面",
        admin_msg("管理用パスワード (delpass.txt) が設定されていません。", false)
      )
    end

    ok = pw != "" and Crypto.verify_hash(pw, delcrypt)

    if Counters.admin_record(who, ok) == :error do
      admin_page(
        "管理画面",
        admin_msg("状態ファイル (admin_fail.mem) を開けないため、受け付けられません。", false)
      )
    end

    ok
  end

  # ---------- 板・スレッドの読み取り ----------
  def admin_read_boards do
    Enum.flat_map(Store.blist_lines(), fn line ->
      p = String.split(line, ",")
      name = hd(p)

      if name == "" or String.starts_with?(name, ".") or String.contains?(name, "/") or
           String.contains?(name, "\\") do
        []
      else
        title = Enum.at(p, 2, "") |> String.replace("#c#", ",")

        plain =
          case :binary.match(title, "alt=\"") do
            {alt, 5} ->
              rest = binary_part(title, alt + 5, byte_size(title) - alt - 5)

              case :binary.match(rest, "\"") do
                {b, 1} -> binary_part(rest, 0, b)
                :nomatch -> ""
              end

            :nomatch ->
              Util.strip_tags(title)
          end

        [%{name: name, plain: plain}]
      end
    end)
  end

  # {表示中, 非表示中} を返す。各要素は新しい順
  def admin_list_threads(folder) do
    {active, hidden} =
      Enum.reduce(Util.list_dir_names(Config.app_path(folder)), {[], []}, fn n, {act, hid} ->
        {x, num} =
          cond do
            byte_size(n) > 6 and String.starts_with?(n, "x") and String.ends_with?(n, ".html") and
                Util.digits?(binary_part(n, 1, byte_size(n) - 6), 1, -1) ->
              {true, binary_part(n, 1, byte_size(n) - 6)}

            Regen.thread_file_name?(n) ->
              {false, binary_part(n, 0, byte_size(n) - 5)}

            true ->
              {false, ""}
          end

        if num == "" do
          {act, hid}
        else
          case Util.file_mtime(Config.app_path([folder, n])) do
            {mt, true} ->
              item = %{mtime: mt, num: num, path: Config.app_path([folder, n])}
              if x, do: {act, [item | hid]}, else: {[item | act], hid}

            _ ->
              {act, hid}
          end
        end
      end)

    by_desc = fn items -> Enum.sort_by(items, & &1.mtime, :desc) end
    {by_desc.(active), by_desc.(hidden)}
  end

  def thread_title_and_count(path) do
    {lines, _} = Util.read_file_lines(path)

    {title, count} =
      Enum.reduce(Enum.with_index(lines), {"", 0}, fn {line, i}, {title, count} ->
        title =
          if i == 0 do
            case Store.extract_first_b(line) do
              {b, true} -> Util.trim_space(Util.html_unescape(b))
              _ -> title
            end
          else
            title
          end

        count =
          case :binary.match(line, "<dt>") do
            {dt, 4} ->
              case Util.parse_leading_int(line, dt + 4) do
                {_, true} -> count + 1
                _ -> count
              end

            :nomatch ->
              count
          end

        {title, count}
      end)

    {title, count}
  end

  def admin_parse_thread(path) do
    {lines, _} = Util.read_file_lines(path)

    {title, rows_rev} =
      Enum.reduce(Enum.with_index(lines), {"", []}, fn {line, i}, {title, rows} ->
        title =
          if i == 0 do
            case Store.extract_first_b(line) do
              {b, true} -> Util.trim_space(Util.html_unescape(b))
              _ -> title
            end
          else
            title
          end

        case :binary.match(line, "<dt>") do
          :nomatch ->
            {title, rows}

          {dt, 4} ->
            case Util.parse_leading_int(line, dt + 4) do
              {num, true} ->
                {title, [parse_res_row(line, num) | rows]}

              _ ->
                {title, rows}
            end
        end
      end)

    {title, Enum.reverse(rows_rev)}
  end

  defp parse_res_row(line, num) do
    name =
      case find_after(line, "投稿者：<font", "><b>") do
        nil ->
          ""

        bs ->
          case find_from(line, " </b>", bs) do
            nil ->
              ""

            be ->
              line
              |> binary_part(bs + 4, be - (bs + 4))
              |> Util.html_unescape()
              |> Util.strip_tags()
              |> Util.trim_space()
          end
      end

    date =
      case find_after(line, "投稿日：", nil) do
        nil ->
          ""

        start ->
          rest = binary_part(line, start, byte_size(line) - start)

          raw =
            case :binary.match(rest, "</font>") do
              {e, _} -> binary_part(rest, 0, e)
              :nomatch -> rest
            end

          raw
          |> Util.trim_space()
          |> String.replace(~r/ ID:[A-Za-z0-9._]+$/, "")
          |> Util.trim_space()
      end

    post_id =
      case find_after(line, "data-id=\"", nil) do
        nil ->
          ""

        start ->
          rest = binary_part(line, start, byte_size(line) - start)

          case :binary.match(rest, "\"") do
            {e, 1} -> binary_part(rest, 0, e)
            :nomatch -> ""
          end
      end

    body =
      case find_after(line, "<dd>", nil) do
        nil ->
          ""

        start ->
          rest = binary_part(line, start, byte_size(line) - start)

          raw =
            case :binary.match(rest, " </dl>") do
              {e, _} -> binary_part(rest, 0, e)
              :nomatch -> rest
            end

          raw
          |> String.replace("<br>", " ")
          |> Util.strip_tags()
          |> Util.html_unescape()
      end

    %{num: num, name: name, date: date, id: post_id, body: body}
  end

  # pat1 を探し、その後ろ (pat2 があればそれも探して、その直後) の位置を返す
  defp find_after(line, pat1, pat2) do
    case :binary.match(line, pat1) do
      :nomatch ->
        nil

      {i, len} ->
        start = i + len

        if pat2 do
          rest = binary_part(line, start, byte_size(line) - start)

          case :binary.match(rest, pat2) do
            :nomatch -> nil
            {j, len2} -> start + j + len2
          end
        else
          start
        end
    end
  end

  defp find_from(line, pat, from) do
    rest = binary_part(line, from, byte_size(line) - from)

    case :binary.match(rest, pat) do
      :nomatch -> nil
      {i, _} -> from + i
    end
  end

  # ---------- 画面 ----------
  def admin_show_boards(pw) do
    rows =
      Enum.map_join(admin_read_boards(), "", fn b ->
        "<tr><td>" <> Util.html_escape(b.name) <> "</td><td>" <> Util.html_escape(b.plain) <>
          "</td><td>" <> admin_btn(pw, "開く", "", "threads", b.name, "", "") <> "</td></tr>"
      end)

    body =
      if rows == "" do
        "<p>板がありません。</p>"
      else
        "<table><tr><th>板</th><th>名称</th><th></th></tr>" <> rows <> "</table>"
      end

    admin_page("板の一覧", body)
  end

  def admin_show_threads(pw, folder, message, ok) do
    {active, hidden} = admin_list_threads(folder)
    body = admin_msg(message, ok) <> admin_nav(pw, "")

    rows =
      active
      |> Enum.take(@admin_list_limit)
      |> Enum.map_join("", fn th ->
        {title, count} = thread_title_and_count(th.path)
        title = if title == "", do: "(題名なし)", else: title
        lock_mark = if Store.thread_is_locked(folder, th.num), do: "🔒", else: ""

        "<tr><td>" <> Util.html_escape(title) <> "</td><td>#{count}</td><td>" <>
          Util.format_admin_time(th.mtime) <> "</td><td>" <> lock_mark <> "</td><td>" <>
          admin_btn(pw, "レスを見る", "", "replies", folder, th.num, "") <> " " <>
          admin_btn(pw, "鍵の管理", "", "keys", folder, th.num, "") <> " " <>
          admin_btn(pw, "非表示", "このスレッドを非表示にします。よろしいですか?", "hide", folder, th.num, "") <>
          "</td></tr>"
      end)

    body =
      if rows != "" do
        b =
          body <>
            "<table><tr><th>題名</th><th>レス数</th><th>更新</th><th>鍵</th><th></th></tr>" <> rows <> "</table>"

        if length(active) > @admin_list_limit do
          b <> "<p>新しい順に #{@admin_list_limit} 件だけ表示しています (全 #{length(active)} 件)。</p>"
        else
          b
        end
      else
        body <> "<p>表示中のスレッドはありません。</p>"
      end

    hrows =
      hidden
      |> Enum.take(@admin_list_limit)
      |> Enum.map_join("", fn th ->
        {title, count} = thread_title_and_count(th.path)
        title = if title == "", do: "(題名なし)", else: title

        "<tr><td>" <> Util.html_escape(title) <> "</td><td>#{count}</td><td>" <>
          Util.format_admin_time(th.mtime) <> "</td><td>" <>
          admin_btn(pw, "復元", "", "restore", folder, th.num, "") <> "</td></tr>"
      end)

    body =
      if hrows != "" do
        body <>
          "<h3>非表示中のスレッド</h3><table><tr><th>題名</th><th>レス数</th><th>更新</th><th></th></tr>" <>
          hrows <> "</table>"
      else
        body
      end

    admin_page("「#{folder}」のスレッド", body)
  end

  def admin_show_replies(pw, folder, res, message, ok) do
    path = Config.app_path([folder, res <> ".html"])

    if not Util.path_exists?(path) do
      admin_fatal(pw, "スレッドがありません。(非表示中の場合は、スレッド一覧から復元してください)")
    end

    {title, rows} = admin_parse_thread(path)

    trs =
      Enum.map_join(rows, "", fn r ->
        cb =
          if r.num != 1 do
            "<input type=\"checkbox\" name=\"del\" value=\"#{r.num}\">"
          else
            "—"
          end

        cps = Util.codepoints_list(r.body)
        short = cps |> Enum.take(@admin_body_preview) |> Util.codepoints_to_string()
        short = if length(cps) > @admin_body_preview, do: short <> "…", else: short

        "<tr><td>" <> cb <> "</td><td>#{r.num}</td><td>" <> Util.html_escape(r.name) <>
          "</td><td>" <> Util.html_escape(r.date) <> "</td><td>" <> Util.html_escape(r.id) <>
          "</td><td class=\"body\">" <> Util.html_escape(short) <> "</td></tr>"
      end)

    title = if title == "", do: "(題名なし)", else: title

    admin_page(
      "#{title} (#{folder}/#{res})",
      admin_msg(message, ok) <> admin_nav(pw, folder) <>
        "<form method=\"post\" action=\"admin.cgi\">" <>
        admin_hidden(pw, [{"act", "delete"}, {"folder", folder}, {"res", res}]) <>
        "<table><tr><th>削除</th><th>No</th><th>名前</th><th>日時</th><th>ID</th><th>本文</th></tr>" <>
        trs <>
        "</table><p><button type=\"submit\" onclick=\"return confirm('選択したレスを削除します。よろしいですか?')\">選択したレスを削除</button></p></form>" <>
        "<p>1番は削除できません。スレッドごと消す場合は「非表示」を使ってください。</p><p>" <>
        admin_btn(pw, "このスレッドを非表示にする", "このスレッドを非表示にします。よろしいですか?", "hide", folder, res, "") <>
        "</p>"
    )
  end

  def admin_show_keys(pw, folder, res, message, ok, issued) do
    path = Config.app_path([folder, res <> ".html"])

    if not Util.path_exists?(path) do
      admin_fatal(pw, "スレッドがありません。")
    end

    {title, _} = thread_title_and_count(path)
    locked = Store.thread_is_locked(folder, res)
    body = admin_msg(message, ok) <> admin_nav(pw, folder)

    body =
      if issued != "" do
        body <>
          "<div class=\"keybox\"><b>キーを発行しました。この画面を閉じると、二度と表示されません。</b><br>いまのうちに控えて、書き込んでよい人に渡してください。<br><br><code>" <>
          Util.html_escape(issued) <> "</code></div>"
      else
        body
      end

    state_text = if locked, do: "🔒 鍵つき (認証キーがないと書き込めません)", else: "鍵なし (誰でも書き込めます)"

    buttons =
      if locked do
        admin_btn(pw, "鍵を外す", "このスレッドの鍵を外して、誰でも書き込めるようにします。よろしいですか?", "unlock", folder, res, "") <>
          " " <> admin_btn(pw, "書き込みフォームを作り直す", "", "lock", folder, res, "")
      else
        admin_btn(pw, "鍵をかける", "このスレッドに鍵をかけます。キーを持たない人は書き込めなくなります。よろしいですか?", "lock", folder, res, "")
      end

    body =
      body <>
        "<p>状態: <b>" <> state_text <> "</b></p><p>" <> buttons <>
        "</p><p>※ 鍵つきでも、読むのは誰でもできます。</p>"

    rows =
      Store.keys_load(folder)
      |> Enum.filter(fn r -> r.scope == "*" or r.scope == res end)
      |> Enum.map_join("", fn r ->
        active = r.status == "active"
        status = if active, do: "有効", else: "失効"

        revoke_btn =
          if active do
            confirm =
              if r.scope == "*" do
                "このキーは、この板の鍵つきスレッド全部で使えなくなります。よろしいですか?"
              else
                "このキーを失効します。よろしいですか?"
              end

            admin_btn(pw, "失効", confirm, "revoke", folder, res, r.id)
          else
            ""
          end

        scope_text = if r.scope == "*", do: "この板の鍵つきスレッドどれでも", else: "このスレッドだけ"

        "<tr><td>" <> Util.html_escape(r.id) <> "</td><td>" <> Util.html_escape(r.label) <>
          "</td><td>" <> scope_text <> "</td><td>" <> Util.format_admin_time(r.created) <>
          "</td><td>" <> status <> "</td><td>" <> revoke_btn <> "</td></tr>"
      end)

    keys_table =
      if rows == "" do
        "<p>このスレッドで使えるキーはまだありません。</p>"
      else
        "<table><tr><th>ID</th><th>ラベル</th><th>範囲</th><th>発行日時</th><th>状態</th><th></th></tr>" <> rows <> "</table>"
      end

    body = body <> "<h3>キー</h3>" <> keys_table

    body =
      body <>
        "<h3>キーを発行する</h3><form method=\"post\" action=\"admin.cgi\">" <>
        admin_hidden(pw, [{"act", "issue"}, {"folder", folder}, {"res", res}]) <>
        "ラベル (誰に渡すか。40文字まで) <input type=\"text\" name=\"label\" size=\"24\"><br>" <>
        "範囲 <label><input type=\"radio\" name=\"scope\" value=\"thread\" checked> このスレッドだけ</label> " <>
        "<label><input type=\"radio\" name=\"scope\" value=\"board\"> この板の鍵つきスレッドどれでも</label><br>" <>
        "<button type=\"submit\">発行</button></form>" <>
        "<p>鍵をかける前にキーを発行しても、あとから発行してもかまいません。キーは発行したときに1度だけ表示されます (サーバーにはハッシュしか残りません)。</p>"

    title = if title == "", do: "(題名なし)", else: title
    admin_page("鍵の管理: #{title} (#{folder}/#{res})", body)
  end

  # ---------- 操作 ----------
  def admin_do_set_lock(folder, res, on) do
    if not Util.path_exists?(Config.app_path([folder, res <> ".html"])) do
      {false, "スレッドがありません。"}
    else
      ok = Post.board!(folder, fn -> Store.thread_set_lock(folder, res, on) end)

      cond do
        not ok -> {false, "鍵の印のファイルを更新できませんでした。"}
        on -> {true, "スレッド #{res} に鍵をかけました。"}
        true -> {true, "スレッド #{res} の鍵を外しました。"}
      end
    end
  end

  # 投稿日文字列をエポック秒にする (Python 版 DATE_RE)。取れなければ nil
  def admin_parse_date_in_line(line) do
    case Regex.run(@date_re, line) do
      [_, y, mo, d, h, mi, s] ->
        Util.jst_to_epoch(
          Util.safe_integer(y, 0),
          Util.safe_integer(mo, 0),
          Util.safe_integer(d, 0),
          Util.safe_integer(h, 0),
          Util.safe_integer(mi, 0),
          Util.safe_integer(s, 0)
        )

      _ ->
        nil
    end
  end

  def admin_do_delete(folder, res, nums) do
    nums = Enum.reject(nums, &(&1 == 1))

    cond do
      nums == [] ->
        {false, "削除するレスが選ばれていません。(1番は削除できません)"}

      not Util.path_exists?(Config.app_path([folder, res <> ".html"])) ->
        {false, "スレッドがありません。"}

      true ->
        path = Config.app_path([folder, res <> ".html"])
        num_set = MapSet.new(nums)

        {removed, err?} =
          Post.board!(folder, fn ->
            case Util.read_file_lines(path) do
              {_, false} ->
                {0, true}

              {lines, true} ->
                {orig_mtime, _} = Util.file_mtime(path)

                {keep_rev, removed, stamp} =
                  Enum.reduce(lines, {[], 0, nil}, fn line, {keep, removed, stamp} ->
                    num =
                      case :binary.match(line, "<dt>") do
                        {dt, 4} ->
                          case Util.parse_leading_int(line, dt + 4) do
                            {n, true} -> n
                            _ -> nil
                          end

                        :nomatch ->
                          nil
                      end

                    if not is_nil(num) and MapSet.member?(num_set, num) do
                      {keep, removed + 1, stamp}
                    else
                      stamp =
                        case admin_parse_date_in_line(line) do
                          nil -> stamp
                          st -> st
                        end

                      {[line | keep], removed, stamp}
                    end
                  end)

                content = keep_rev |> Enum.reverse() |> Enum.map_join("", fn l -> l <> "\n" end)

                if Util.write_file_string(path, content) do
                  new_ts = stamp || orig_mtime

                  if not is_nil(stamp) or orig_mtime > 0 do
                    Util.set_file_mtime(path, new_ts + 1)
                  end

                  {removed, false}
                else
                  {0, true}
                end
            end
          end)

        if err? do
          {false, "削除中にファイルエラーが発生しました。"}
        else
          {true, "#{removed}件のレスを削除しました。"}
        end
    end
  end

  def admin_do_hide(folder, res) do
    src = Config.app_path([folder, res <> ".html"])
    dst = Config.app_path([folder, "x" <> res <> ".html"])

    Post.board!(folder, fn ->
      cond do
        not Util.path_exists?(src) ->
          {false, "スレッドがありません。"}

        Util.path_exists?(dst) ->
          {false, "同じ番号の非表示スレッドが既にあるため、処理できません。"}

        Util.rename_path(src, dst) ->
          Util.chmod_file(dst, 0o600)
          {true, "スレッド #{res} を非表示にしました。"}

        true ->
          {false, "スレッドの非表示化に失敗しました。"}
      end
    end)
  end

  def admin_do_restore(folder, res) do
    src = Config.app_path([folder, "x" <> res <> ".html"])
    dst = Config.app_path([folder, res <> ".html"])

    Post.board!(folder, fn ->
      cond do
        not Util.path_exists?(src) ->
          {false, "非表示のスレッドがありません。"}

        Util.path_exists?(dst) ->
          {false, "同じ番号の表示中スレッドが既にあるため、復元できません。"}

        Util.rename_path(src, dst) ->
          Util.chmod_file(dst, 0o644)
          {true, "スレッド #{res} を復元しました。"}

        true ->
          {false, "スレッドの復元に失敗しました。"}
      end
    end)
  end

  def admin_regen(folder) do
    {_name, status} = Post.board!(folder, fn -> Regen.regen_index(folder, 1, false, false) end)

    if status != "done" do
      " (他の処理が再生成中のため、板の一覧の更新は省略されました)"
    else
      ""
    end
  end

  # ---------- メイン ----------
  # parse_qs 相当: キー -> 値のリスト
  def parse_admin_params(octs) do
    if octs == "" or is_nil(octs) do
      %{}
    else
      s = Util.utf8_decode(octs)

      Enum.reduce(String.split(s, "&"), %{}, fn pair, table ->
        {k, v, _} = Util.split_once(pair, ?=)
        key = Util.url_decode(k)
        Map.update(table, key, [Util.url_decode(v)], fn vs -> vs ++ [Util.url_decode(v)] end)
      end)
    end
  end

  def handle_admin(%Req{} = req) do
    Exit.run_handler(fn -> admin_main(req) end)
  end

  def admin_main(%Req{} = req) do
    params =
      if req.method == "POST" do
        if byte_size(req.body || "") > @admin_max_body do
          admin_page("エラー", admin_msg("送信内容が大きすぎます。", false))
        end

        parse_admin_params(req.body)
      else
        %{}
      end

    get1 = fn key -> params |> Map.get(key, []) |> List.first() || "" end
    get_all = fn key -> Map.get(params, key, []) end

    pw = get1.("adminpass")

    if req.method != "POST" or pw == "" do
      admin_login_page("")
    end

    if not admin_authenticate(pw, req) do
      admin_login_page("パスワードが違います。")
    end

    act = get1.("act")

    if act == "" or act == "boards" do
      admin_show_boards(pw)
    end

    folder = get1.("folder")

    if folder == "" or String.contains?(folder, "/") or String.contains?(folder, "\\") or
         String.contains?(folder, "..") or not Store.is_board(folder) do
      admin_fatal(pw, "板名が不正です。")
    end

    if act == "threads" do
      admin_show_threads(pw, folder, "", true)
    end

    res = get1.("res")

    if not Util.digits?(res, 1, 20) do
      admin_fatal(pw, "スレッド番号が不正です。")
    end

    case act do
      "replies" ->
        admin_show_replies(pw, folder, res, "", true)

      "keys" ->
        admin_show_keys(pw, folder, res, "", true, "")

      x when x in ["lock", "unlock"] ->
        {ok, message} = admin_do_set_lock(folder, res, x == "lock")
        message = if ok, do: message <> admin_regen(folder), else: message
        admin_show_keys(pw, folder, res, message, ok, "")

      "issue" ->
        scope = if get1.("scope") == "board", do: "*", else: res
        {_id, issued} = Post.board!(folder, fn -> Store.key_issue(folder, get1.("label"), scope) end)

        if issued == "" do
          admin_show_keys(pw, folder, res, "キーを保存できませんでした。", false, "")
        else
          admin_show_keys(pw, folder, res, admin_regen(folder), true, issued)
        end

      "revoke" ->
        key_id = get1.("id")

        id_ok =
          String.length(key_id) == 4 and
            Enum.all?(String.graphemes(key_id), fn c -> String.contains?(Config.key_alphabet(), c) end)

        ok = id_ok and Post.board!(folder, fn -> Store.key_revoke(folder, key_id) end)

        message =
          if ok do
            "キー #{key_id} を失効しました。" <> admin_regen(folder)
          else
            "キーを失効できませんでした。"
          end

        admin_show_keys(pw, folder, res, message, ok, "")

      "delete" ->
        nums =
          get_all.("del")
          |> Enum.filter(fn x -> Util.digits?(x, 1, 6) end)
          |> Enum.map(fn x -> Util.safe_integer(x, 0) end)

        {ok, message} = admin_do_delete(folder, res, nums)
        message = if ok, do: message <> admin_regen(folder), else: message
        admin_show_replies(pw, folder, res, message, ok)

      "hide" ->
        {ok, message} = admin_do_hide(folder, res)
        message = if ok, do: message <> admin_regen(folder), else: message
        admin_show_threads(pw, folder, message, ok)

      "restore" ->
        {ok, message} = admin_do_restore(folder, res)
        message = if ok, do: message <> admin_regen(folder), else: message
        admin_show_threads(pw, folder, message, ok)

      _ ->
        admin_fatal(pw, "不明な操作です。")
    end
  end
end
