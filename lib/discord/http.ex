defmodule Discord.HTTP do
  @moduledoc """
  Thin HTTP transport built on `Req`. Knows nothing about Discord —
  just shapes requests, decodes JSON, and normalises responses to
  `{:ok, %{status:, body:, headers:}}` or `{:error, reason}`.

  Discord-specific concerns (base URL, auth, endpoints) live in
  `Discord.Bots.API` and other clients above this layer.
  """

  @default_receive_timeout 15_000

  def get(url, headers \\ [], opts \\ []) do
    request(:get, url, headers, nil, opts)
  end

  def post(url, body, headers \\ [], opts \\ []) do
    request(:post, url, headers, body, opts)
  end

  def request(method, url, headers, body, opts) do
    req_opts =
      [
        method: method,
        url: url,
        headers: headers,
        receive_timeout: @default_receive_timeout
      ]
      |> Keyword.merge(opts)
      |> put_body(body)

    case Req.request(req_opts) do
      {:ok, %Req.Response{status: status, body: body, headers: headers}} ->
        {:ok, %{status: status, body: body, headers: headers}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp put_body(opts, nil), do: opts
  defp put_body(opts, body) when is_map(body) or is_list(body), do: Keyword.put(opts, :json, body)
  defp put_body(opts, body), do: Keyword.put(opts, :body, body)
end
