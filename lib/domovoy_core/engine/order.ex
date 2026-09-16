defmodule DomovoyCore.Engine.Order do
  @moduledoc """
  Puts the nodes of a `DomovoyCore.Graph` in an order that respects each arrow.

  The order is a topological sort with Kahn's algorithm. It reads
  `graph.predecessors` and `graph.successors`, and it looks only at the names
  in `nodes_by_name`. A name in `graph.inputs` is not a node. The caller or
  Store gives it, so it counts as satisfied from the start.

  `waves/1` groups the nodes for inspection. Each wave holds nodes whose
  predecessors appear in earlier waves. Nodes in one wave do not depend on
  each other. `order/1` gives the same result with the waves put end to end.

  `DomovoyCore.Engine` does not run these waves as fixed batches. It starts a node
  when all its predecessors finish successfully and a task slot is free.
  Therefore a successor can start before unrelated nodes from an earlier wave
  finish. The Engine also calls `waves/1` before execution to reject an invalid
  graph that contains a cycle.

  Inside a wave the names are sorted. Therefore one graph always gives one
  order, and a test can assert it.

  A graph with a cycle has no order. Then this module gives
  `DomovoyCore.Error.graph_has_cycle/1` with the names that it could not place.

  ## How a wave is computed

  The algorithm keeps one number for each node: how many of its predecessors
  are nodes that have not run yet. It does four things.

  1. **Count.** For each node, count its predecessors that are in
     `nodes_by_name`. An external input does not count.
  2. **Start.** Every node at zero is in the first wave. Sort the names.
  3. **Release.** Take every successor of every node in the wave, and lower
     its count by one. Each successor that reaches zero is in the next wave.
     Sort the names, and repeat this step until a wave is empty.
  4. **Check.** If a node never reached zero, it waits for a node that waits
     for it. Those names are the cycle, and the result is an error.

  For the diamond below, step 1 gives this table:

  | Node | Node predecessors | Count |
  | --- | --- | --- |
  | `a` | none | 0 |
  | `b` | `a` | 1 |
  | `c` | `a` | 1 |
  | `d` | `b`, `c` | 2 |

  Step 2 puts `a` in wave 0. Step 3 lowers `b` and `c` to zero, so they are
  wave 1. The next release lowers `d` twice, once for `b` and once for `c`. It
  reaches zero on the second one, so `d` is wave 2. `d` appears once, because
  it reaches zero once.

  ## Examples

  Each example builds its nodes with one small function, so the shape of the
  graph is easy to read. A diagram shows each wave as a column.

  ### A chain

  A chain gives one wave for each node, in the order of the arrows. No nodes
  can become ready at the same time:

  ```mermaid
  flowchart LR
    subgraph w0 [wave 0]
      a
    end
    subgraph w1 [wave 1]
      b
    end
    subgraph w2 [wave 2]
      c
    end
    a --> b --> c
  ```

      node = fn name, deps ->
        DomovoyCore.Node.new(%{
          name: name,
          runner: MyApp.Runner.Delay,
          type: DomovoyCore.Type.Integer,
          after: deps
        })
      end
      graph = DomovoyCore.Graph.new([node.("c", ["b"]), node.("b", ["a"]), node.("a", [])])
      DomovoyCore.Engine.Order.waves(graph)
      {:ok, [["a"], ["b"], ["c"]]}
      DomovoyCore.Engine.Order.order(graph)
      {:ok, ["a", "b", "c"]}

  ### A diamond

  A fan-out and a join. The two middle nodes depend only on `a`, so they are
  one wave. `d` waits for both:

  ```mermaid
  flowchart LR
    subgraph w0 [wave 0]
      a
    end
    subgraph w1 [wave 1]
      b
      c
    end
    subgraph w2 [wave 2]
      d
    end
    a --> b --> d
    a --> c --> d
  ```

      node = fn name, deps ->
        DomovoyCore.Node.new(%{
          name: name,
          runner: MyApp.Runner.Delay,
          type: DomovoyCore.Type.Integer,
          after: deps
        })
      end
      graph =
        DomovoyCore.Graph.new([
          node.("d", ["b", "c"]),
          node.("c", ["a"]),
          node.("b", ["a"]),
          node.("a", [])
        ])
      DomovoyCore.Engine.Order.waves(graph)
      {:ok, [["a"], ["b", "c"], ["d"]]}

  ### A join that waits for the longest path

  `d` depends on `a` and on `c`. `a` is done after wave 0, but `d` cannot run
  before `c`, and `c` is wave 2. A node goes into the wave after its latest
  predecessor, not after its earliest one:

  ```mermaid
  flowchart LR
    subgraph w0 [wave 0]
      a
    end
    subgraph w1 [wave 1]
      b
    end
    subgraph w2 [wave 2]
      c
    end
    subgraph w3 [wave 3]
      d
    end
    a --> b --> c --> d
    a --> d
  ```

      node = fn name, deps ->
        DomovoyCore.Node.new(%{
          name: name,
          runner: MyApp.Runner.Delay,
          type: DomovoyCore.Type.Integer,
          after: deps
        })
      end
      graph =
        DomovoyCore.Graph.new([
          node.("d", ["a", "c"]),
          node.("c", ["b"]),
          node.("b", ["a"]),
          node.("a", [])
        ])
      DomovoyCore.Engine.Order.waves(graph)
      {:ok, [["a"], ["b"], ["c"], ["d"]]}

  ### Many sources, many sinks

  Four producers start together. Each later wave holds every node whose
  predecessors are all in earlier waves, so the width of a wave follows the
  shape of the graph:

  ```mermaid
  flowchart LR
    subgraph w0 [wave 0]
      a
      b
      c
      d
    end
    subgraph w1 [wave 1]
      e
      f
    end
    subgraph w2 [wave 2]
      g
      h
      i
    end
    subgraph w3 [wave 3]
      j
      k
    end
    a --> e --> g --> j
    a --> g
    b --> e
    c --> f --> h --> j
    d --> f
    d --> i --> k
    e --> h
    f --> i
    h --> k
  ```

      node = fn name, deps ->
        DomovoyCore.Node.new(%{
          name: name,
          runner: MyApp.Runner.Delay,
          type: DomovoyCore.Type.Integer,
          after: deps
        })
      end
      graph =
        DomovoyCore.Graph.new([
          node.("j", ["g", "h"]),
          node.("k", ["h", "i"]),
          node.("g", ["a", "e"]),
          node.("h", ["e", "f"]),
          node.("i", ["d", "f"]),
          node.("e", ["a", "b"]),
          node.("f", ["c", "d"]),
          node.("a", []),
          node.("b", []),
          node.("c", []),
          node.("d", [])
        ])
      DomovoyCore.Engine.Order.waves(graph)
      {:ok, [["a", "b", "c", "d"], ["e", "f"], ["g", "h", "i"], ["j", "k"]]}

  ### Two graphs in one, and an isolated node

  Nodes that share no arrow still share the waves. `alone` and `x` are both
  ready at the start, so the inspection puts them in one wave:

  ```mermaid
  flowchart LR
    subgraph w0 [wave 0]
      alone
      x
    end
    subgraph w1 [wave 1]
      y
    end
    x --> y
  ```

      node = fn name, deps ->
        DomovoyCore.Node.new(%{
          name: name,
          runner: MyApp.Runner.Delay,
          type: DomovoyCore.Type.Integer,
          after: deps
        })
      end
      graph = DomovoyCore.Graph.new([node.("y", ["x"]), node.("x", []), node.("alone", [])])
      DomovoyCore.Engine.Order.waves(graph)
      {:ok, [["alone", "x"], ["y"]]}

  ### External inputs

  `path` is a binding source that no node of the graph gives, so it is in
  `graph.inputs` and not in `nodes_by_name`. It does not count as a
  predecessor. Both nodes that read it are ready at once:

  ```mermaid
  flowchart LR
    path([input: path])
    subgraph w0 [wave 0]
      checksum
      decode
    end
    subgraph w1 [wave 1]
      verify
    end
    path -.-> decode --> verify
    path -.-> checksum --> verify
  ```

      decode =
        DomovoyCore.Node.new(%{
          name: "decode",
          runner: MyApp.Runner.Compute,
          type: DomovoyCore.Type.Integer,
          bind: %{path: {"path", DomovoyCore.Type.Integer}}
        })
      checksum =
        DomovoyCore.Node.new(%{
          name: "checksum",
          runner: MyApp.Runner.Compute,
          type: DomovoyCore.Type.Integer,
          bind: %{path: {"path", DomovoyCore.Type.Integer}}
        })
      verify =
        DomovoyCore.Node.new(%{
          name: "verify",
          runner: MyApp.Runner.Compute,
          type: DomovoyCore.Type.Integer,
          bind: %{left: {"decode", DomovoyCore.Type.Integer}, right: {"checksum", DomovoyCore.Type.Integer}}
        })
      graph = DomovoyCore.Graph.new([verify, decode, checksum])
      graph.inputs
      %{"path" => DomovoyCore.Type.Integer}
      DomovoyCore.Engine.Order.waves(graph)
      {:ok, [["checksum", "decode"], ["verify"]]}

  ### The shape of a real Stage

  This is the graph of the `prepare` Stage of `IssueToPrWorkflow`, with the
  runners replaced. `issue_id` is an input of the workflow. The graph is a
  chain with one fork at the start: the Linear configuration and the issue
  identifier do not need each other, so they share one wave. Every later node
  waits for the one before it:

  ```mermaid
  flowchart LR
    issue_id([input: issue_id])
    subgraph w0 [wave 0]
      enhance_issue_identifier
      read_linear_config
    end
    subgraph w1 [wave 1]
      linear_get_issue
    end
    subgraph w2 [wave 2]
      target_branch
    end
    subgraph w3 [wave 3]
      worktree_name
    end
    subgraph w4 [wave 4]
      worktree
    end
    subgraph w5 [wave 5]
      worktree_exists
    end
    subgraph w6 [wave 6]
      create_worktree_or_skip
    end
    subgraph w7 [wave 7]
      target_branch_checkout_or_skip
    end
    subgraph w8 [wave 8]
      debug_print
    end
    issue_id -.-> enhance_issue_identifier --> linear_get_issue
    read_linear_config --> linear_get_issue
    linear_get_issue --> target_branch --> worktree_name --> worktree
    worktree --> worktree_exists --> create_worktree_or_skip
    worktree --> create_worktree_or_skip
    create_worktree_or_skip --> target_branch_checkout_or_skip
    target_branch --> target_branch_checkout_or_skip
    target_branch_checkout_or_skip --> debug_print
    issue_id -.-> debug_print
    enhance_issue_identifier --> debug_print
    target_branch --> debug_print
    worktree_name --> debug_print
  ```

      node = fn name, deps ->
        bind = Map.new(deps, &{&1, {Atom.to_string(&1), DomovoyCore.Type.Integer}})
        DomovoyCore.Node.new(%{
          name: name,
          runner: MyApp.Runner.Compute,
          type: DomovoyCore.Type.Integer,
          bind: bind
        })
      end
      graph =
        DomovoyCore.Graph.new([
          node.("read_linear_config", []),
          node.("enhance_issue_identifier", [:issue_id]),
          node.("linear_get_issue", [:enhance_issue_identifier, :read_linear_config]),
          node.("target_branch", [:linear_get_issue]),
          node.("worktree_name", [:target_branch]),
          node.("worktree", [:worktree_name]),
          node.("worktree_exists", [:worktree]),
          node.("create_worktree_or_skip", [:worktree, :worktree_exists]),
          node.("target_branch_checkout_or_skip", [:create_worktree_or_skip, :target_branch]),
          node.("debug_print", [
            :issue_id,
            :enhance_issue_identifier,
            :target_branch,
            :worktree_name,
            :target_branch_checkout_or_skip
          ])
        ])
      DomovoyCore.Engine.Order.waves(graph)
      {:ok,
       [
         ["enhance_issue_identifier", "read_linear_config"],
         ["linear_get_issue"],
         ["target_branch"],
         ["worktree_name"],
         ["worktree"],
         ["worktree_exists"],
         ["create_worktree_or_skip"],
         ["target_branch_checkout_or_skip"],
         ["debug_print"]
       ]}

  ### A cycle

  `a`, `b` and `c` wait for each other, so none of them reaches zero. `d`
  waits for `c`, so it never reaches zero either. The error names the cycle
  and every node behind it. `start` and `after` have a place, but a graph with
  a cycle has no order, so the result is the error and not a partial list:

  ```mermaid
  flowchart LR
    start --> after
    a --> b --> c --> a
    c --> d
    classDef stuck fill:#fee2e2,stroke:#b91c1c,color:#7f1d1d;
    class a,b,c,d stuck;
  ```

      node = fn name, deps ->
        DomovoyCore.Node.new(%{
          name: name,
          runner: MyApp.Runner.Delay,
          type: DomovoyCore.Type.Integer,
          after: deps
        })
      end
      nodes = [
          node.("start", []),
          node.("after", ["start"]),
          node.("a", ["c"]),
          node.("b", ["a"]),
          node.("c", ["b"]),
          node.("d", ["c"])
        ]
      DomovoyCore.Graph.new(nodes)
      %DomovoyCore.Error{type: :graph_has_cycle, reason: %{node: ["a", "b", "c", "d"]}}
      arrows = DomovoyCore.Arrow.from_nodes(nodes)
      graph = %DomovoyCore.Graph{nodes_by_name: Map.new(nodes, &{&1.name, &1}),
        predecessors: DomovoyCore.Arrow.predecessors(arrows), successors: DomovoyCore.Arrow.successors(arrows)}
      DomovoyCore.Engine.Order.waves(graph)
      %DomovoyCore.Error{type: :graph_has_cycle, reason: %{node: ["a", "b", "c", "d"]}}
      DomovoyCore.Engine.Order.order(graph)
      %DomovoyCore.Error{type: :graph_has_cycle, reason: %{node: ["a", "b", "c", "d"]}}
  """

  alias DomovoyCore.Error
  alias DomovoyCore.Graph
  alias DomovoyCore.Node

  @typedoc "The nodes that can become ready after every earlier wave completes."
  @type wave() :: [Node.name()]

  @typedoc "The number of node predecessors that each node still waits for."
  @type pending() :: %{Node.name() => non_neg_integer()}

  @doc """
  Gives the names of the nodes of `graph` in an order that respects each arrow.

  See the moduledoc for the rules and for examples.
  """
  @spec order(graph :: Graph.t()) :: {:ok, [Node.name()]} | Error.t()
  def order(%Graph{} = graph) do
    case waves(graph) do
      {:ok, waves} -> {:ok, List.flatten(waves)}
      %Error{} = error -> error
    end
  end

  @doc """
  Gives the nodes of `graph` in waves. The nodes of one wave depend on none of
  each other, and each of them depends only on nodes of an earlier wave.

  See the moduledoc for the rules and for examples.
  """
  @spec waves(graph :: Graph.t()) :: {:ok, [wave()]} | Error.t()
  def waves(%Graph{} = graph) do
    node_names = graph.nodes_by_name |> Map.keys() |> MapSet.new()
    pending = pending(graph, node_names)
    ready = pending |> Enum.filter(&satisfied?/1) |> Enum.map(&elem(&1, 0)) |> Enum.sort()

    ready
    |> visit(pending, graph.successors, node_names, [])
    |> finish(node_names)
  end

  @spec pending(graph :: Graph.t(), node_names :: MapSet.t(Node.name())) :: pending()
  defp pending(%Graph{} = graph, node_names) do
    Map.new(node_names, fn name ->
      count =
        graph.predecessors
        |> Map.get(name, [])
        |> Enum.count(&MapSet.member?(node_names, &1))

      {name, count}
    end)
  end

  @spec satisfied?(entry :: {Node.name(), non_neg_integer()}) :: boolean()
  defp satisfied?({_name, count}), do: count == 0

  @spec visit(
          wave :: wave(),
          pending :: pending(),
          successors :: %{Node.name() => [Node.name()]},
          node_names :: MapSet.t(Node.name()),
          placed :: [wave()]
        ) :: [wave()]
  defp visit([], _pending, _successors, _node_names, placed), do: Enum.reverse(placed)

  defp visit(wave, pending, successors, node_names, placed) do
    {pending, released} =
      wave
      |> Enum.flat_map(&Map.get(successors, &1, []))
      |> Enum.filter(&MapSet.member?(node_names, &1))
      |> release(pending)

    visit(Enum.sort(released), pending, successors, node_names, [wave | placed])
  end

  @spec release(names :: [Node.name()], pending :: pending()) :: {pending(), wave()}
  defp release(names, pending) do
    Enum.reduce(names, {pending, []}, fn name, {pending, released} ->
      count = Map.fetch!(pending, name) - 1
      pending = Map.put(pending, name, count)

      if count == 0 do
        {pending, [name | released]}
      else
        {pending, released}
      end
    end)
  end

  @spec finish(placed :: [wave()], node_names :: MapSet.t(Node.name())) ::
          {:ok, [wave()]} | Error.t()
  defp finish(placed, node_names) do
    placed_names = List.flatten(placed)

    if length(placed_names) == MapSet.size(node_names) do
      {:ok, placed}
    else
      node_names
      |> MapSet.difference(MapSet.new(placed_names))
      |> Enum.sort()
      |> Error.graph_has_cycle()
    end
  end
end
