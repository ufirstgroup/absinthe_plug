defmodule Absinthe.Plug.Request do
  @moduledoc false

  # This struct is the default return type of Request.parse.
  # It contains parsed Request structs -- typically just one,
  # but when `batched` is set to true, it can be multiple.
  #
  # extra_keys: e.g. %{"id": ...} sent by react-relay-network-layer,
  #             which need to be merged back into the list of final results
  #             before sending it to the client

  import Plug.Conn
  alias Absinthe.Plug.Request.Query

  defstruct [
    queries: [],
    batch: false,
    extra_keys: [],
  ]

  @type t :: %__MODULE__{
    queries: list(Absinthe.Plug.Request.Query.t),
    batch: boolean(),
    extra_keys: list(map()),
  }

  @spec parse(Plug.Conn.t, map) :: {:ok, t} | {:input_error, String.t}
  def parse(conn, config) do
    root_value =
      config
      |> Map.get(:root_value, %{})
      |> Map.merge(extract_root_value(conn))

    context =
      config
      |> Map.get(:context, %{})
      |> Map.merge(extract_context(conn, config))

    config = Map.merge(config, %{
      context: context,
      root_value: root_value,
    })

    with {_conn, {body, params}} <- extract_body_and_params(conn) do
      # Phoenix puts parsed params under the "_json" key when the
      # structure is an array; otherwise it's just the keys themselves,
      # and they may sit in the body or in the params
      batch? = Map.has_key?(params, "_json")
      build_request(body, params, config, batch?: batch?)
    end
  end

  defp build_request(_body, params, config, batch?: true) do
    queries = Enum.map(params["_json"], fn query ->
      Query.parse("", query, config)
    end)

    extra_keys = Enum.map(params["_json"], fn query ->
      Map.drop(query, ["query", "variables"])
    end)

    request = %__MODULE__{
      queries: queries,
      batch: true,
      extra_keys: extra_keys,
    }
    {:ok, request}
  end
  defp build_request(body, params, config, batch?: false) do
    queries =
      body
      |> Query.parse(params, config)
      |> List.wrap

    request = %__MODULE__{
      queries: queries,
      batch: false,
    }

    {:ok, request}
  end


  #
  # BODY / PARAMS
  #

  @spec extract_body_and_params(Plug.Conn.t) :: {Plug.Conn.t, {String.t, map}}
  defp extract_body_and_params(%{body_params: %{"query" => _}} = conn) do
    conn = fetch_query_params(conn)
    {conn, {"", conn.params}}
  end
  defp extract_body_and_params(conn) do
    {:ok, body, conn} = read_body(conn)
    conn = fetch_query_params(conn)
    {conn, {body, conn.params}}
  end

  #
  # CONTEXT
  #

  @spec extract_context(Plug.Conn.t, map) :: map
  defp extract_context(conn, config) do
    config.context
    |> Map.merge(conn.private[:absinthe][:context] || %{})
    |> Map.merge(uploaded_files(conn))
  end

  #
  # UPLOADED FILES
  #

  @spec uploaded_files(Plug.Conn.t) :: map
  defp uploaded_files(conn) do
    files =
      conn.params
      |> Enum.filter(&match?({_, %Plug.Upload{}}, &1))
      |> Map.new

    %{
      __absinthe_plug__: %{
        uploads: files
      }
    }
  end


  #
  # ROOT VALUE
  #

  @spec extract_root_value(Plug.Conn.t) :: any
  defp extract_root_value(conn) do
    conn.private[:absinthe][:root_value] || %{}
  end

  @spec log(t) :: :ok
  def log(request, level \\ :debug) do
    Enum.each(request.queries, &Query.log(&1, level))
    :ok
  end
end
