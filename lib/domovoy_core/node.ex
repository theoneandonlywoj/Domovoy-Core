defmodule DomovoyCore.Node do
  @moduledoc """
  Declares a runner, its output type, and its inputs.

  A runner declares every input with its type. `bind` maps a field to `{source, type}`, where the
  source is a producer node name. `args` maps a field to `{value, type}`. `new/1` turns each `bind`
  entry into a `DomovoyCore.Binding` and keeps each `args` tuple.
  A declared type must equal the schema field type. An extra field on an `extra?: true` runner takes
  the declared type as its own.

  Literal arguments get their casts at execution. `after` names nodes that must finish first and
  supplies no parameters.

  Static errors raise `ArgumentError` with names and types, never argument values.
  Required fields need a binding, an argument, or a non-empty schema default.

  ## Examples

      node = DomovoyCore.Node.new(%{name: "read", runner: MyApp.Runner.File,
        type: DomovoyCore.Type.String, args: %{path: {"PLAN.md", DomovoyCore.Type.String}},
        bind: %{working_directory: {"worktree_directory", DomovoyCore.Type.Directory}}})
      node.bind.working_directory
      %DomovoyCore.Binding{from: "worktree_directory", type: DomovoyCore.Type.Directory, metadata: %{}}
      node.args.path
      {"PLAN.md", DomovoyCore.Type.String}
      DomovoyCore.Node.store?(node)
      true

      DomovoyCore.Node.new(%{name: "../read", runner: MyApp.Runner.File, type: DomovoyCore.Type.String})
      ** (ArgumentError) invalid_node: %{expected: :valid_name, node: "../read"}

      DomovoyCore.Node.new(%{name: "read", runner: MyApp.Runner.File,
        type: DomovoyCore.Type.String, bind: %{unknown: {"source", DomovoyCore.Type.String}}})
      ** (ArgumentError) invalid_node: %{expected: :schema_field, field: :unknown, node: "read", source: "source"}

      DomovoyCore.Node.new(%{name: "read", runner: MyApp.Runner.File,
        type: DomovoyCore.Type.String, args: %{unknown: {"secret", DomovoyCore.Type.String}}})
      ** (ArgumentError) invalid_node: %{expected: :schema_field, field: :unknown, node: "read"}

      DomovoyCore.Node.new(%{name: "read", runner: MyApp.Runner.File, type: DomovoyCore.Type.String,
        args: %{path: {"secret", DomovoyCore.Type.String}}, bind: %{path: {"source", DomovoyCore.Type.String}}})
      ** (ArgumentError) invalid_node: %{actual: :bind_and_args, expected: :one_input, field: :path, node: "read", source: "source"}

      DomovoyCore.Node.new(%{name: "read", runner: MyApp.Runner.File, type: DomovoyCore.Type.String})
      ** (ArgumentError) invalid_node: %{actual: :missing, expected: :required_input, field: :path, node: "read"}

      DomovoyCore.Node.new(%{name: "read", runner: MyApp.Runner.File,
        type: DomovoyCore.Type.String, bind: %{path: %DomovoyCore.Binding{from: "source", type: DomovoyCore.Type.String}}})
      ** (ArgumentError) invalid_node: %{expected: {:source, DomovoyCore.Type}, field: :path, node: "read"}

      DomovoyCore.Node.new(%{name: "read", runner: MyApp.Runner.File,
        type: DomovoyCore.Type.String, args: %{path: "secret"}})
      ** (ArgumentError) invalid_node: %{expected: {:value, DomovoyCore.Type}, field: :path, node: "read"}

      DomovoyCore.Node.new(%{name: "read", runner: MyApp.Runner.File,
        type: DomovoyCore.Type.String, args: %{path: {"PLAN.md", DomovoyCore.Name}}})
      ** (ArgumentError) invalid_node: %{actual: DomovoyCore.Name, expected: DomovoyCore.Type, field: :path, node: "read"}

      DomovoyCore.Node.new(%{name: "read", runner: MyApp.Runner.File,
        type: DomovoyCore.Type.String, bind: %{path: {"source.path", DomovoyCore.Type.String}}})
      ** (ArgumentError) invalid_node: %{expected: :valid_source, field: :path, node: "read", source: "source.path"}

      DomovoyCore.Node.new(%{name: "read", runner: MyApp.Runner.File, type: DomovoyCore.Type.String,
        bind: %{path: {"source", DomovoyCore.Type.Integer}}})
      ** (ArgumentError) invalid_node: %{actual: DomovoyCore.Type.Integer, expected: DomovoyCore.Type.String, field: :path, node: "read", source: "source"}

      DomovoyCore.Node.new(%{name: "read", runner: MyApp.Runner.File, type: DomovoyCore.Type.String,
        args: %{path: {"PLAN.md", DomovoyCore.Type.Directory}}})
      ** (ArgumentError) invalid_node: %{actual: DomovoyCore.Type.Directory, expected: DomovoyCore.Type.String, field: :path, node: "read"}

      DomovoyCore.Node.new(%{name: "read", runner: MyApp.Runner.File, type: DomovoyCore.Type.String,
        args: %{path: {"PLAN.md", DomovoyCore.Type.String}}, retry: [max_attempts: 0]})
      ** (ArgumentError) invalid_node: %{actual: :invalid_retry, expected: DomovoyCore.Retry, field: :retry, node: "read"}

      DomovoyCore.Node.new(%{name: "read", runner: MyApp.Runner.File,
        type: DomovoyCore.Type.String, depends_on: %{"source" => DomovoyCore.Type.String}})
      ** (ArgumentError) invalid_node: %{expected: :supported_input, field: :depends_on, node: "read"}

      DomovoyCore.Node.new(%{name: "read", runner: MyApp.Runner.File,
        type: DomovoyCore.Type.String, validations: []})
      ** (ArgumentError) invalid_node: %{expected: :supported_input, field: :validations, node: "read"}
  """

  alias DomovoyCore.Binding
  alias DomovoyCore.Name
  alias DomovoyCore.Node
  alias DomovoyCore.Retry
  alias DomovoyCore.Runner
  alias DomovoyCore.Type

  @type name() :: String.t()
  @type metadata() :: %{String.t() => any()}

  @type t() :: %Node{
          name: name(),
          metadata: metadata(),
          bind: %{atom() => Binding.t()},
          args: %{atom() => arg()},
          after: [name()],
          validators: [module()],
          retry: Retry.t(),
          store?: boolean(),
          runner: Runner,
          type: Type.t()
        }

  @typedoc "A literal argument with the type its field expects."
  @type arg() :: {term(), Type.t()}

  @type new() :: map()

  @type nodes_names_to_many_nodes_names() :: %{name() => [name()]}

  @type nodes_grouped_by_name() :: %{name() => t()}

  defstruct name: "node_name_not_set",
            metadata: %{},
            bind: %{},
            args: %{},
            after: [],
            validators: [],
            retry: %Retry{},
            store?: true,
            runner: nil,
            type: nil

  @spec new(new()) :: Node.t()
  def new(args) do
    name = Map.fetch!(args, :name)
    runner = Map.fetch!(args, :runner)
    type = Map.fetch!(args, :type)
    metadata = args[:metadata] || %{}

    reject_removed_inputs!(name, args)

    unless Name.valid?(name), do: invalid!(%{node: name, expected: :valid_name})

    node = %Node{
      name: name,
      metadata: metadata,
      bind: Map.get(args, :bind, %{}),
      args: Map.get(args, :args, %{}),
      after: Map.get(args, :after, []),
      validators: Map.get(args, :validators, []),
      retry: retry!(name, Map.get(args, :retry, []), runner.__domovoy_core__(:retry)),
      store?: Map.get(args, :store?, true),
      runner: runner,
      type: type
    }

    validate_inputs!(node)
  end

  @spec reject_removed_inputs!(name :: name(), args :: map()) :: :ok
  defp reject_removed_inputs!(name, args) do
    for field <- [:depends_on, :validations] do
      if Map.has_key?(args, field) do
        invalid!(%{node: name, field: field, expected: :supported_input})
      end
    end

    :ok
  end

  @spec validate_inputs!(Node.t()) :: Node.t()
  defp validate_inputs!(node) do
    schema = node.runner.__domovoy_core__(:input)
    fields = schema.__schema__(:fields)
    extra? = node.runner.__domovoy_core__(:extra?)

    bindings =
      node.bind
      |> Enum.sort()
      |> Map.new(fn {field, entry} ->
        diagnostic = %{node: node.name, field: field}

        unless match?({source, type} when is_binary(source) and is_atom(type), entry),
          do: invalid!(Map.put(diagnostic, :expected, {:source, Type}))

        {source, type} = entry
        diagnostic = Map.put(diagnostic, :source, source)
        field!(field, fields, extra?, diagnostic)

        if Map.has_key?(node.args, field),
          do: invalid!(Map.merge(diagnostic, %{expected: :one_input, actual: :bind_and_args}))

        declared_type!(type, schema.__schema__(:type, field), diagnostic)
        {field, binding!(source, type, diagnostic)}
      end)

    node.args
    |> Enum.sort()
    |> Enum.each(fn {field, entry} ->
      diagnostic = %{node: node.name, field: field}

      unless match?({_value, type} when is_atom(type), entry),
        do: invalid!(Map.put(diagnostic, :expected, {:value, Type}))

      {_value, type} = entry
      field!(field, fields, extra?, diagnostic)
      declared_type!(type, schema.__schema__(:type, field), diagnostic)
    end)

    defaults = struct(schema)

    node.runner.__domovoy_core__(:required)
    |> Enum.sort()
    |> Enum.each(fn field ->
      supplied? = Map.has_key?(bindings, field) or Map.has_key?(node.args, field)
      default? = defaults |> Map.get(field) |> default_present?()

      unless supplied? or default? do
        invalid!(%{node: node.name, field: field, expected: :required_input, actual: :missing})
      end
    end)

    %{node | bind: bindings}
  end

  @spec field!(field :: term(), fields :: [atom()], extra? :: boolean(), diagnostic :: map()) ::
          :ok
  defp field!(field, fields, extra?, diagnostic) do
    unless is_atom(field) and (field in fields or extra?),
      do: invalid!(Map.put(diagnostic, :expected, :schema_field))

    :ok
  end

  @spec declared_type!(declared :: term(), schema_type :: Type.t() | nil, diagnostic :: map()) ::
          :ok
  defp declared_type!(declared, schema_type, diagnostic) do
    cond do
      not Type.type?(declared) ->
        invalid!(Map.merge(diagnostic, %{expected: Type, actual: declared}))

      is_nil(schema_type) or declared == schema_type ->
        :ok

      true ->
        invalid!(Map.merge(diagnostic, %{expected: schema_type, actual: declared}))
    end
  end

  @spec binding!(source :: String.t(), type :: Type.t(), diagnostic :: map()) :: Binding.t()
  defp binding!(source, type, diagnostic) do
    Binding.new(source, type)
  rescue
    ArgumentError -> invalid!(Map.put(diagnostic, :expected, :valid_source))
  end

  @spec default_present?(term()) :: boolean()
  defp default_present?(value) when is_binary(value), do: String.trim(value) != ""
  defp default_present?(value) when is_map(value), do: map_size(value) > 0
  defp default_present?(value), do: value not in [nil, []]

  @spec retry!(name :: name(), options :: term(), defaults :: Retry.t()) :: Retry.t()
  defp retry!(name, options, defaults) do
    Retry.new(options, defaults)
  rescue
    ArgumentError ->
      invalid!(%{node: name, field: :retry, expected: Retry, actual: :invalid_retry})
  end

  @spec invalid!(map()) :: no_return()
  defp invalid!(diagnostic) do
    entries =
      [:actual, :expected, :field, :node, :source]
      |> Enum.filter(&Map.has_key?(diagnostic, &1))
      |> Enum.map_join(", ", fn key -> "#{key}: #{inspect(Map.fetch!(diagnostic, key))}" end)

    raise ArgumentError, "invalid_node: %{#{entries}}"
  end

  @doc """
  Returns the raw metadata value for `key`, or `nil` when it is not present.
  """
  @spec get_metadata(node :: Node.t(), key :: String.t()) :: any() | nil
  def get_metadata(%Node{} = node, key) do
    Map.get(node.metadata, key)
  end

  @doc """
  Returns the `store?` field. If false, the Engine keeps the record in memory only.
  """
  @spec store?(Node.t()) :: boolean()
  def store?(%Node{store?: store?}), do: store?
end
