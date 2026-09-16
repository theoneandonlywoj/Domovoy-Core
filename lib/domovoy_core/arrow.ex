defmodule DomovoyCore.Arrow do
  @moduledoc """
  One arrow of a graph or of a workflow.

  An arrow joins two names. Graph arrows come from `bind` and `after`.
  Bindings carry data. `after` only sets execution order.
  Workflow arrows move the cursor between vertices. An arrow holds no kind because its declaration supplies that information.

  ## Examples

      iex> DomovoyCore.Arrow.new("a", "b")
      %DomovoyCore.Arrow{from: "a", to: "b"}

      iex> arrows = [DomovoyCore.Arrow.new("a", "c"), DomovoyCore.Arrow.new("b", "c")]
      iex> DomovoyCore.Arrow.predecessors(arrows)
      %{"c" => ["a", "b"]}
      iex> DomovoyCore.Arrow.successors(arrows)
      %{"a" => ["c"], "b" => ["c"]}
  """

  alias DomovoyCore.Arrow
  alias DomovoyCore.Node
  alias DomovoyCore.Vertex

  @typedoc "The name at one end of an arrow: a node in a graph, a vertex in a workflow."
  @type endpoint() :: Node.name() | Vertex.name()

  @type t() :: %Arrow{
          from: endpoint(),
          to: endpoint()
        }

  @typedoc "The names on one side of the arrows, grouped by the name on the other side."
  @type adjacency() :: %{endpoint() => [endpoint()]}

  defstruct from: nil,
            to: nil

  @spec new(from :: endpoint(), to :: endpoint()) :: Arrow.t()
  def new(from, to) do
    %Arrow{
      from: from,
      to: to
    }
  end

  @spec from_node(Node.t()) :: [Arrow.t()]
  def from_node(%Node{} = node) do
    sources = Enum.map(node.bind, fn {_field, binding} -> binding.from end)

    (sources ++ node.after)
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.map(fn dependency_name -> new(dependency_name, node.name) end)
  end

  @spec from_nodes([Node.t()]) :: [Arrow.t()]
  def from_nodes(nodes) do
    nodes
    |> Enum.flat_map(fn node -> from_node(node) end)
    |> Enum.uniq()
    |> Enum.sort_by(&{&1.from, &1.to})
  end

  @doc """
  Groups the `from` names of `arrows` by their `to` name.
  """
  @spec predecessors([Arrow.t()]) :: adjacency()
  def predecessors(arrows) do
    arrows
    |> Enum.group_by(fn arrow -> arrow.to end)
    |> Enum.map(fn
      {name, arrows} ->
        {name, Enum.map(arrows, fn arrow -> arrow.from end)}
    end)
    |> Map.new()
  end

  @doc """
  Groups the `to` names of `arrows` by their `from` name.
  """
  @spec successors([Arrow.t()]) :: adjacency()
  def successors(arrows) do
    arrows
    |> Enum.group_by(fn arrow -> arrow.from end)
    |> Enum.map(fn
      {name, arrows} ->
        {name, Enum.map(arrows, fn arrow -> arrow.to end)}
    end)
    |> Map.new()
  end
end
