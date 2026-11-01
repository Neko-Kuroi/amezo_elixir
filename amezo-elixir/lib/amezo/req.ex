defmodule Amezo.Req do
  @moduledoc "リクエストの抽象 (Go 版 core.go の request と同じ)"
  defstruct method: "GET",
            query_string: "",
            body: "",
            headers: [],
            remote_addr: "",
            script_name: ""

  def header(%__MODULE__{headers: headers}, name) do
    down = String.downcase(name)

    Enum.find_value(headers, "", fn {k, v} ->
      if String.downcase(k) == down, do: v, else: nil
    end)
  end
end

defmodule Amezo.Resp do
  @moduledoc "レスポンスの抽象"
  defstruct status: 200, headers: [], body: ""
end

defmodule Amezo.Exit do
  @moduledoc """
  Python 版の error()/redirect() の sys.exit、Go 版の panic/recover に当たる早期脱出。
  throw で抜けて、ハンドラの境界 (run_handler/1、Board.run/2) でレスポンスに変換する。
  """
  alias Amezo.{Resp, Util}

  def bail(resp), do: throw({:amezo_bail, resp})

  def html_header_response(body, status, extra \\ []) do
    %Resp{
      status: status,
      headers: [{"Content-Type", "text/html; charset=UTF-8"}] ++ extra,
      body: body
    }
  end

  # Python 版 amezo.error(): 200 でエラー文を出して終わる
  def page_error(msg) do
    bail(
      html_header_response(
        "<html><head><meta http-equiv=\"Content-Type\" content=\"text/html; charset=UTF-8\"></head><body><h2>" <>
          Util.html_escape(msg) <> "</h2></body></html>",
        200
      )
    )
  end

  def redirect_response(folder, index_name) do
    target = Util.html_escape(folder <> "/" <> index_name)

    bail(%Resp{
      status: 303,
      headers: [
        {"Location", "../" <> target},
        {"Content-Type", "text/html; charset=UTF-8"}
      ],
      body:
        "<html><head><meta http-equiv=\"refresh\" content=\"0;url=../" <>
          target <> "\"></head><body>Redirecting to <a href=\"../" <> target <> "\">" <> target <> "</a>...</body></html>"
    })
  end

  @doc "ハンドラを実行し、bail をレスポンスに変換する"
  def run_handler(fun) do
    try do
      fun.()
    catch
      {:amezo_bail, resp} -> resp
    end
  end
end
