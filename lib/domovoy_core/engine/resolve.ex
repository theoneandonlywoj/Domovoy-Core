defmodule DomovoyCore.Engine.Resolve do
  @moduledoc """
  Resolves the bindings of a typed runner.

  A resolver first reads a successful record from the current Engine run. If
  no record exists there, it reads the newest successful record from the
  store at the current job generation. It checks that each source value has
  the type that the binding declares.

  A literal argument for a schema field passes through unchanged, because
  `DomovoyCore.Runner.changeset/2` casts it with the input schema. A literal
  argument for an extra field has no schema field, so the resolver casts it
  with its declared type, as it does for an extra binding.

  ## Examples

      job = DomovoyCore.Job.new("resolve-example")
      value = DomovoyCore.Value.cast!(".", DomovoyCore.Type.Directory)
      record = DomovoyCore.Record.new(%{job: job, node: "worktree_directory", status: :ok, result: value})
      node = DomovoyCore.Node.new(%{
        name: "read",
        runner: MyApp.Runner.File,
        type: DomovoyCore.Type.String,
        args: %{path: {"README.md", DomovoyCore.Type.String}},
        bind: %{working_directory: {"worktree_directory", DomovoyCore.Type.Directory}}
      })
      context = %DomovoyCore.Context{job: job, node: "read"}
      {:ok, params} = DomovoyCore.Engine.Resolve.params(node, %{"worktree_directory" => record}, context, node.runner)
      params.path
      "README.md"
      params.working_directory == File.cwd!()
      true
  """

  alias DomovoyCore.Binding
  alias DomovoyCore.Context
  alias DomovoyCore.Error
  alias DomovoyCore.Job
  alias DomovoyCore.Node
  alias DomovoyCore.Record
  alias DomovoyCore.Store
  alias DomovoyCore.Type
  alias DomovoyCore.Value

  @doc """
  Gives the resolved parameter map or a redacted error.

  `effective_runner` identifies the schema selected for execution. Node and
  Engine validation ensure that its schema is compatible with the node.
  """
  @spec params(
          node :: Node.t(),
          records :: %{Node.name() => Record.t()},
          context :: Context.t(),
          effective_runner :: module()
        ) :: {:ok, map()} | Error.t()
  def params(%Node{} = node, records, %Context{} = context, effective_runner)
      when is_map(records) and is_atom(effective_runner) do
    with {:ok, params} <- literals(node, effective_runner) do
      node.bind
      |> Enum.sort()
      |> Enum.reduce_while({:ok, params}, &bound(&1, &2, node, records, context))
    end
  end

  @spec bound(
          {atom(), Binding.t()},
          {:ok, map()},
          Node.t(),
          %{Node.name() => Record.t()},
          Context.t()
        ) :: {:cont, {:ok, map()}} | {:halt, Error.t()}
  defp bound({field, binding}, {:ok, params}, node, records, context) do
    case resolve(binding, field, node, records, context) do
      {:ok, raw} -> {:cont, {:ok, Map.put(params, field, raw)}}
      %Error{} = error -> {:halt, error}
    end
  end

  @spec literals(node :: Node.t(), effective_runner :: module()) :: {:ok, map()} | Error.t()
  defp literals(%Node{} = node, effective_runner) do
    fields = effective_runner.__domovoy_core__(:input).__schema__(:fields)

    node.args
    |> Enum.sort()
    |> Enum.reduce_while({:ok, %{}}, fn {field, {value, type}}, {:ok, params} ->
      case literal(field in fields, value, type) do
        {:ok, raw} ->
          {:cont, {:ok, Map.put(params, field, raw)}}

        :error ->
          {:halt,
           %Error{
             type: :argument_cast_failed,
             reason: %{node: node.name, field: field, expected: type}
           }}
      end
    end)
  end

  @spec literal(schema_field? :: boolean(), value :: term(), type :: Type.t()) ::
          {:ok, term()} | :error
  defp literal(true, value, _type), do: {:ok, value}

  defp literal(false, value, type) do
    case Value.cast(value, type) do
      {:ok, %Value{value: cast}} -> {:ok, cast}
      {:error, %Error{}} -> :error
    end
  end

  @spec resolve(
          binding :: Binding.t(),
          field :: atom(),
          node :: Node.t(),
          records :: %{Node.name() => Record.t()},
          context :: Context.t()
        ) :: {:ok, term()} | Error.t()
  defp resolve(%Binding{} = binding, field, %Node{} = node, records, %Context{} = context) do
    case value(binding.from, records, context) do
      {:ok, %Value{} = value} ->
        cast(binding, field, node, value)

      :miss ->
        %Error{
          type: :binding_source_not_found,
          reason: %{node: node.name, field: field, source: binding.from}
        }

      {:error, %Error{} = error} ->
        error
    end
  end

  @spec value(source :: Node.name(), records :: map(), context :: Context.t()) ::
          {:ok, Value.t()} | :miss | {:error, Error.t()}
  defp value(source, records, %Context{} = context) do
    case Map.get(records, source) do
      %Record{status: :ok, result: %Value{} = value} -> {:ok, value}
      %Record{} -> stored_value(source, context)
      nil -> stored_value(source, context)
    end
  end

  @spec stored_value(source :: Node.name(), context :: Context.t()) ::
          {:ok, Value.t()} | :miss | {:error, Error.t()}
  defp stored_value(_source, %Context{store: nil}), do: :miss

  defp stored_value(source, %Context{store: store, job: %Job{} = job}) do
    case Store.latest(store, source, job.generation) do
      {:ok, %Record{status: :ok, result: %Value{} = value}} -> {:ok, value}
      :miss -> :miss
      {:error, %Error{} = error} -> {:error, error}
    end
  end

  @spec cast(
          binding :: Binding.t(),
          field :: atom(),
          node :: Node.t(),
          source_value :: Value.t()
        ) :: {:ok, term()} | Error.t()
  defp cast(%Binding{} = binding, field, node, %Value{} = value) do
    if binding.type in [Type.Any, value.type] do
      {:ok, value.value}
    else
      cast_error(binding, field, node, value.type)
    end
  end

  @spec cast_error(
          binding :: Binding.t(),
          field :: atom(),
          node :: Node.t(),
          actual :: term()
        ) :: Error.t()
  defp cast_error(%Binding{} = binding, field, %Node{} = node, actual) do
    %Error{
      type: :binding_cast_failed,
      reason: %{
        node: node.name,
        field: field,
        source: binding.from,
        expected: binding.type,
        actual: actual
      }
    }
  end
end
