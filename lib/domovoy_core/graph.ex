defmodule DomovoyCore.Graph do
  @moduledoc """
  Validates node names, data types, and execution order before execution.

  `new/1` returns a graph or a `DomovoyCore.Error`. It sorts nodes and edges for deterministic diagnostics.
  Data edges come from `bind`. Control edges come from `after` and carry no data.
  Each `after` source must name a node in this graph. External data sources appear in `inputs`.

  A binding must match its producer type, unless the expected type is `DomovoyCore.Type.Any`.
  Two different concrete types for one external source conflict. `Any` never conflicts with a concrete source type.

  Cycles fail at construction. The error names the cycle and all nodes that wait behind it, in sorted order.
  `DomovoyCore.Engine.Order` also checks cycles in graphs that bypass this constructor.

  ## Examples

      source = DomovoyCore.Node.new(%{name: "source", runner: MyApp.Runner.Delay, type: DomovoyCore.Type.String})
      read = DomovoyCore.Node.new(%{name: "read", runner: MyApp.Runner.Prompt, type: DomovoyCore.Type.String,
        args: %{template: {"{{text}}", DomovoyCore.Type.String}}, bind: %{text: {"source", DomovoyCore.Type.String}}})
      graph = DomovoyCore.Graph.new([read, source])
      graph.arrows
      [%DomovoyCore.Arrow{from: "source", to: "read"}]
      DomovoyCore.Engine.Order.waves(graph)
      {:ok, [["source"], ["read"]]}

      DomovoyCore.Graph.new([%DomovoyCore.Node{name: "a"}, %DomovoyCore.Node{name: "a"}])
      %DomovoyCore.Error{type: :duplicate_node_name, reason: %{node: "a"}}

      a = DomovoyCore.Node.new(%{name: "a", runner: MyApp.Runner.Count, type: DomovoyCore.Type.Integer,
        bind: %{count: {"input", DomovoyCore.Type.Integer}}})
      b = DomovoyCore.Node.new(%{name: "b", runner: MyApp.Runner.Label, type: DomovoyCore.Type.String,
        bind: %{text: {"input", DomovoyCore.Type.String}}})
      DomovoyCore.Graph.new([b, a])
      %DomovoyCore.Error{type: :conflicting_input_types,
        reason: %{node: "b", field: :text, source: "input", expected: DomovoyCore.Type.Integer, actual: DomovoyCore.Type.String}}

      a = DomovoyCore.Node.new(%{name: "a", runner: MyApp.Runner.Delay, type: DomovoyCore.Type.Integer})
      b = DomovoyCore.Node.new(%{name: "b", runner: MyApp.Runner.Prompt, type: DomovoyCore.Type.String,
        args: %{template: {"{{text}}", DomovoyCore.Type.String}}, bind: %{text: {"a", DomovoyCore.Type.String}}})
      DomovoyCore.Graph.new([b, a])
      %DomovoyCore.Error{type: :binding_type_mismatch,
        reason: %{node: "b", field: :text, source: "a", expected: DomovoyCore.Type.String, actual: DomovoyCore.Type.Integer}}

      DomovoyCore.Graph.new([%DomovoyCore.Node{name: "read", after: ["missing"]}])
      %DomovoyCore.Error{type: :after_source_not_found, reason: %{node: "read", source: "missing"}}

      DomovoyCore.Graph.new([%DomovoyCore.Node{name: "b", after: ["a"]}, %DomovoyCore.Node{name: "a", after: ["b"]}])
      %DomovoyCore.Error{type: :graph_has_cycle, reason: %{node: ["a", "b"]}}
  """

  alias DomovoyCore.Arrow
  alias DomovoyCore.Engine.Order
  alias DomovoyCore.Error
  alias DomovoyCore.Graph
  alias DomovoyCore.Node
  alias DomovoyCore.Type

  defstruct nodes_by_name: %{},
            arrows: [],
            predecessors: %{},
            successors: %{},
            inputs: %{}

  @type t() :: %Graph{
          nodes_by_name: Node.nodes_grouped_by_name(),
          arrows: [Arrow.t()],
          predecessors: %{Node.name() => [Node.name()]},
          successors: %{Node.name() => [Node.name()]},
          inputs: %{Node.name() => Type.t()}
        }

  @doc """
  Makes a graph, or returns the first static error in deterministic order.
  """
  @spec new([Node.t()]) :: Graph.t() | Error.t()
  def new(nodes \\ []) do
    nodes = Enum.sort_by(nodes, & &1.name)

    with :ok <- unique_names(nodes),
         nodes_by_name = Map.new(nodes, &{&1.name, &1}),
         :ok <- control_sources(nodes, nodes_by_name),
         {:ok, inputs} <- data_sources(nodes, nodes_by_name) do
      arrows = Arrow.from_nodes(nodes)

      graph = %Graph{
        nodes_by_name: nodes_by_name,
        arrows: arrows,
        predecessors: Arrow.predecessors(arrows),
        successors: Arrow.successors(arrows),
        inputs: inputs
      }

      case Order.waves(graph) do
        {:ok, _waves} -> graph
        %Error{} = error -> error
      end
    end
  end

  @spec unique_names([Node.t()]) :: :ok | Error.t()
  defp unique_names([%Node{name: name}, %Node{name: name} | _rest]),
    do: %Error{type: :duplicate_node_name, reason: %{node: name}}

  defp unique_names([_node | rest]), do: unique_names(rest)
  defp unique_names([]), do: :ok

  @spec control_sources(nodes :: [Node.t()], nodes_by_name :: Node.nodes_grouped_by_name()) ::
          :ok | Error.t()
  defp control_sources(nodes, nodes_by_name) do
    nodes
    |> Enum.flat_map(fn node -> Enum.map(node.after, &{node.name, &1}) end)
    |> Enum.sort()
    |> Enum.find(fn {_node, source} -> not Map.has_key?(nodes_by_name, source) end)
    |> case do
      nil ->
        :ok

      {node, source} ->
        %Error{type: :after_source_not_found, reason: %{node: node, source: source}}
    end
  end

  @spec data_sources(nodes :: [Node.t()], nodes_by_name :: Node.nodes_grouped_by_name()) ::
          {:ok, map()} | Error.t()
  defp data_sources(nodes, nodes_by_name) do
    nodes
    |> Enum.flat_map(fn node ->
      Enum.map(node.bind, fn {field, binding} ->
        {node.name, field, binding.from, binding.type}
      end)
    end)
    |> Enum.sort()
    |> Enum.reduce_while({:ok, %{}}, fn {node, field, source, type}, {:ok, inputs} ->
      diagnostic = %{node: node, field: field, source: source, expected: type}

      case data_source(Map.get(nodes_by_name, source), diagnostic, inputs) do
        {:ok, inputs} -> {:cont, {:ok, inputs}}
        %Error{} = error -> {:halt, error}
      end
    end)
  end

  @spec data_source(
          producer :: Node.t() | nil,
          diagnostic :: map(),
          inputs :: map()
        ) ::
          {:ok, map()} | Error.t()
  defp data_source(nil, diagnostic, inputs) do
    type = diagnostic.expected
    first = Map.get(inputs, diagnostic.source, Type.Any)

    cond do
      first == Type.Any ->
        {:ok, Map.put(inputs, diagnostic.source, type)}

      type in [Type.Any, first] ->
        {:ok, inputs}

      true ->
        %Error{
          type: :conflicting_input_types,
          reason: Map.merge(diagnostic, %{expected: first, actual: type})
        }
    end
  end

  defp data_source(producer, diagnostic, inputs) do
    if diagnostic.expected in [Type.Any, producer.type] do
      {:ok, inputs}
    else
      %Error{type: :binding_type_mismatch, reason: Map.put(diagnostic, :actual, producer.type)}
    end
  end
end
