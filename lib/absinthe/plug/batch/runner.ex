defmodule Absinthe.Plug.Batch.Runner do

  @moduledoc false

  alias Absinthe.Plug.Request

  def run(queries, conn, config) do
    queries = build_pipelines(queries, conn, config)

    queries = prepare(queries)

    {valid_queries, invalid_queries} = Enum.split_with(queries, fn
      {:ok, _, _, _} -> true
      {:error, _, _, _} -> false
    end)

    valid_results = valid_queries |> build_valid_results(config.schema_mod)
    invalid_results = invalid_queries |> build_invalid_results

    restore_order(valid_results, invalid_results)
  end

  defp restore_order(valid_results, invalid_results) do
    valid_results ++ invalid_results
    |> Enum.sort_by(fn {i, _q} -> i end)
    |> Enum.map(fn {_i, q} -> q end)
  end

  defp build_valid_results(valid_queries, schema) do
    blueprints = Enum.map(valid_queries, fn
      {:ok, bp, query, _index} ->
        {:ok, bp, _} = Absinthe.Pipeline.run(bp, prep_pipeline(query))
        bp
    end)

    querys_and_indices = Enum.map(valid_queries, fn
      {:ok, _bp, query, index} -> {query, index}
    end)

    blueprints
    |> Absinthe.Plug.Batch.Resolver.resolve(schema: schema)
    |> Enum.zip(querys_and_indices)
    |> Enum.map(fn {bp, {query, i}} ->
      # if it doesn't return this I'm not sure what to do.
      {:ok, %{result: result}, _} = Absinthe.Pipeline.run(bp, result_pipeline(query))

      {i, result}
    end)
  end

  defp build_invalid_results(invalid_queries) do
    Enum.map(invalid_queries, fn {:error, bp, query, i} ->
      # if it doesn't return this I'm not sure what to do.
      {:ok, %{result: result}, _} = Absinthe.Pipeline.run(bp, result_pipeline(query))

      {i, result}

    end)
  end

  defp prepare(queries) do
    for {query, i} <- Enum.with_index(queries) do
      case Absinthe.Pipeline.run(query.document, validation_pipeline(query)) do
        {:ok, bp, _} ->
          case bp.resolution.validation_errors do
            [] ->
              {:ok, bp, query, i}
            _ ->
              {:error, bp, query, i}
          end
        other ->
          raise "#{inspect other}"
      end
    end
  end

  defp build_pipelines(queries, conn, config) do
    for query <- queries do
      query
      |> Map.update!(:raw_options, &([jump_phases: false] ++ &1))
      |> Request.Query.add_pipeline(conn, config)
    end
  end

  defp validation_pipeline(%{pipeline: pipeline}) do
    pipeline
    |> Absinthe.Pipeline.upto(Absinthe.Phase.Document.Validation.Result)
  end

  defp prep_pipeline(%{pipeline: pipeline}) do
    pipeline
    |> Absinthe.Pipeline.from(Absinthe.Phase.Document.Validation.Result)
    |> Absinthe.Pipeline.before(Absinthe.Phase.Document.Execution.Resolution)
    |> Enum.drop(1)
  end

  defp result_pipeline(%{pipeline: pipeline}) do
    pipeline
    |> Absinthe.Pipeline.from(Absinthe.Phase.Document.Execution.Resolution)
    |> Enum.drop(1)
  end
end
