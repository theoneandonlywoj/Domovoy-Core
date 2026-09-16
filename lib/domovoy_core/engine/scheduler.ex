defmodule DomovoyCore.Engine.Scheduler do
  @moduledoc """
  Tracks the ready, running, retry, and completed nodes of one graph run.

  The scheduler is pure. It starts no process and reads no clock, store, or
  journal. `DomovoyCore.Engine` owns those effects.

  `ready/1` gives one ready node in sorted order. `complete/3` releases each
  successor as soon as all its predecessors complete. `fail/4` either reserves
  another attempt or halts the graph. A halt classifies active retries as
  cancelled and unstarted nodes as skipped.

  Successful hits count as completed before scheduling starts. External graph
  inputs never enter the ready queue.

  ## Examples

  A chain releases one node at a time:

      node = fn name, bind ->
        DomovoyCore.Node.new(%{
          name: name,
          runner: MyApp.Runner.Prompt,
          type: DomovoyCore.Type.Integer,
          args: %{template: {"1", DomovoyCore.Type.String}},
          bind: bind
        })
      end
      record = fn name ->
        value = DomovoyCore.Value.cast!(1, DomovoyCore.Type.Integer)
        DomovoyCore.Record.new(%{job: DomovoyCore.Job.new("scheduler"), node: name, status: :ok, result: value})
      end
      graph = DomovoyCore.Graph.new([
        node.("c", %{input: {"b", DomovoyCore.Type.Integer}}),
        node.("b", %{input: {"a", DomovoyCore.Type.Integer}}),
        node.("a", %{})
      ])
      scheduler = DomovoyCore.Engine.Scheduler.new(graph, %{})
      {{"a", 1}, scheduler} = DomovoyCore.Engine.Scheduler.ready(scheduler)
      scheduler = DomovoyCore.Engine.Scheduler.complete(scheduler, "a", record.("a"))
      {{"b", 1}, _scheduler} = DomovoyCore.Engine.Scheduler.ready(scheduler)

  A diamond join waits for both middle nodes. One fan-out successor becomes
  ready immediately after its predecessor completes:

      node = fn name, bind ->
        DomovoyCore.Node.new(%{
          name: name,
          runner: MyApp.Runner.Prompt,
          type: DomovoyCore.Type.Integer,
          args: %{template: {"1", DomovoyCore.Type.String}},
          bind: bind
        })
      end
      record = fn name ->
        value = DomovoyCore.Value.cast!(1, DomovoyCore.Type.Integer)
        DomovoyCore.Record.new(%{job: DomovoyCore.Job.new("scheduler"), node: name, status: :ok, result: value})
      end
      graph = DomovoyCore.Graph.new([
        node.("d", %{left: {"b", DomovoyCore.Type.Integer}, right: {"c", DomovoyCore.Type.Integer}}),
        node.("c", %{input: {"a", DomovoyCore.Type.Integer}}),
        node.("b", %{input: {"a", DomovoyCore.Type.Integer}}),
        node.("a", %{})
      ])
      scheduler = DomovoyCore.Engine.Scheduler.new(graph, %{})
      {{"a", 1}, scheduler} = DomovoyCore.Engine.Scheduler.ready(scheduler)
      scheduler = DomovoyCore.Engine.Scheduler.complete(scheduler, "a", record.("a"))
      {{"b", 1}, scheduler} = DomovoyCore.Engine.Scheduler.ready(scheduler)
      {{"c", 1}, scheduler} = DomovoyCore.Engine.Scheduler.ready(scheduler)
      scheduler = DomovoyCore.Engine.Scheduler.complete(scheduler, "b", record.("b"))
      {nil, _scheduler} = DomovoyCore.Engine.Scheduler.ready(scheduler)

  A hit releases its successor and remains in the final records:

      node = fn name, bind ->
        DomovoyCore.Node.new(%{
          name: name,
          runner: MyApp.Runner.Prompt,
          type: DomovoyCore.Type.Integer,
          args: %{template: {"1", DomovoyCore.Type.String}},
          bind: bind
        })
      end
      record = fn name ->
        value = DomovoyCore.Value.cast!(1, DomovoyCore.Type.Integer)
        DomovoyCore.Record.new(%{job: DomovoyCore.Job.new("scheduler"), node: name, status: :ok, result: value})
      end
      graph = DomovoyCore.Graph.new([
        node.("b", %{input: {"a", DomovoyCore.Type.Integer}}),
        node.("a", %{})
      ])
      hit = record.("a")
      scheduler = DomovoyCore.Engine.Scheduler.new(graph, %{"a" => hit})
      {{"b", 1}, scheduler} = DomovoyCore.Engine.Scheduler.ready(scheduler)
      DomovoyCore.Engine.Scheduler.records(scheduler)["a"] == hit
      true

  A retry uses the next ordinal. An exhausted failure halts the scheduler:

      graph = DomovoyCore.Graph.new([%DomovoyCore.Node{name: "a"}])
      failed = fn attempt ->
        error = %DomovoyCore.Error{type: :runner_failed, retryable?: true}
        job = DomovoyCore.Job.new("scheduler") |> DomovoyCore.Job.at_attempt(attempt)
        DomovoyCore.Record.new(%{job: job, node: "a", status: :error, result: error})
      end
      scheduler = DomovoyCore.Engine.Scheduler.new(graph, %{})
      {{"a", 1}, scheduler} = DomovoyCore.Engine.Scheduler.ready(scheduler)
      retry = %DomovoyCore.Retry{max_attempts: 2}
      {:retry, 2, scheduler} = DomovoyCore.Engine.Scheduler.fail(scheduler, "a", failed.(1), retry)
      scheduler = DomovoyCore.Engine.Scheduler.retry_ready(scheduler, "a")
      {{"a", 2}, scheduler} = DomovoyCore.Engine.Scheduler.ready(scheduler)
      {:halt, scheduler} = DomovoyCore.Engine.Scheduler.fail(scheduler, "a", failed.(2), retry)
      DomovoyCore.Engine.Scheduler.halted?(scheduler)
      true

  A terminal failure cancels running nodes and skips unstarted nodes:

      node = fn name, bind ->
        DomovoyCore.Node.new(%{
          name: name,
          runner: MyApp.Runner.Prompt,
          type: DomovoyCore.Type.Integer,
          args: %{template: {"1", DomovoyCore.Type.String}},
          bind: bind
        })
      end
      graph = DomovoyCore.Graph.new([
        node.("after", %{input: {"fail", DomovoyCore.Type.Integer}}),
        node.("fail", %{}),
        node.("running", %{})
      ])
      error = %DomovoyCore.Error{type: :runner_failed}
      failed = DomovoyCore.Record.new(%{job: DomovoyCore.Job.new("scheduler"), node: "fail", status: :error, result: error})
      scheduler = DomovoyCore.Engine.Scheduler.new(graph, %{})
      {{"fail", 1}, scheduler} = DomovoyCore.Engine.Scheduler.ready(scheduler)
      {{"running", 1}, scheduler} = DomovoyCore.Engine.Scheduler.ready(scheduler)
      {:halt, scheduler} = DomovoyCore.Engine.Scheduler.fail(scheduler, "fail", failed, %DomovoyCore.Retry{})
      DomovoyCore.Engine.Scheduler.cancelled(scheduler)
      ["running"]
      DomovoyCore.Engine.Scheduler.skipped(scheduler)
      ["after"]

  """

  alias DomovoyCore.Error
  alias DomovoyCore.Graph
  alias DomovoyCore.Job
  alias DomovoyCore.Node
  alias DomovoyCore.Record
  alias DomovoyCore.Retry

  @type t() :: %__MODULE__{
          graph: Graph.t(),
          pending: %{Node.name() => non_neg_integer()},
          ready: [Node.name()],
          running: MapSet.t(Node.name()),
          retrying: MapSet.t(Node.name()),
          attempts: %{Node.name() => pos_integer()},
          records: %{Node.name() => Record.t()},
          halted?: boolean(),
          cancelled: [Node.name()],
          skipped: [Node.name()]
        }

  defstruct graph: nil,
            pending: %{},
            ready: [],
            running: MapSet.new(),
            retrying: MapSet.new(),
            attempts: %{},
            records: %{},
            halted?: false,
            cancelled: [],
            skipped: []

  @doc "Makes scheduling state from `graph` and its successful graph-node hits."
  @spec new(graph :: Graph.t(), hits :: %{Node.name() => Record.t()}) :: t()
  def new(%Graph{} = graph, hits) when is_map(hits) do
    node_names = graph.nodes_by_name |> Map.keys() |> MapSet.new()

    hits =
      hits
      |> Map.take(MapSet.to_list(node_names))
      |> Map.filter(fn {_name, record} -> match?(%Record{status: :ok}, record) end)

    hit_names = hits |> Map.keys() |> MapSet.new()

    pending =
      Map.new(node_names, fn name ->
        count =
          graph.predecessors
          |> Map.get(name, [])
          |> Enum.count(&(MapSet.member?(node_names, &1) and not MapSet.member?(hit_names, &1)))

        {name, count}
      end)

    ready =
      pending
      |> Enum.filter(fn {name, count} -> count == 0 and not MapSet.member?(hit_names, name) end)
      |> Enum.map(&elem(&1, 0))
      |> Enum.sort()

    %__MODULE__{
      graph: graph,
      pending: pending,
      ready: ready,
      attempts: Map.new(node_names, &{&1, 1}),
      records: hits
    }
  end

  @doc "Removes and gives the first ready node, or gives `nil`."
  @spec ready(t()) :: {{Node.name(), pos_integer()} | nil, t()}
  def ready(%__MODULE__{halted?: true} = scheduler), do: {nil, scheduler}
  def ready(%__MODULE__{ready: []} = scheduler), do: {nil, scheduler}

  def ready(%__MODULE__{ready: [name | rest]} = scheduler) do
    scheduler = %__MODULE__{
      scheduler
      | ready: rest,
        running: MapSet.put(scheduler.running, name),
        retrying: MapSet.delete(scheduler.retrying, name)
    }

    {{name, Map.fetch!(scheduler.attempts, name)}, scheduler}
  end

  @doc "Makes a retry eligible for the ready queue after its backoff ends."
  @spec retry_ready(scheduler :: t(), node_name :: Node.name()) :: t()
  def retry_ready(%__MODULE__{halted?: true} = scheduler, _node_name), do: scheduler

  def retry_ready(%__MODULE__{} = scheduler, node_name) do
    if MapSet.member?(scheduler.retrying, node_name) do
      %__MODULE__{scheduler | ready: insert_sorted(scheduler.ready, node_name)}
    else
      scheduler
    end
  end

  @doc "Completes one running node and releases each satisfied successor."
  @spec complete(scheduler :: t(), node_name :: Node.name(), record :: Record.t()) :: t()
  def complete(%__MODULE__{} = scheduler, node_name, %Record{status: :ok} = record) do
    scheduler = %__MODULE__{
      scheduler
      | running: MapSet.delete(scheduler.running, node_name),
        records: Map.put(scheduler.records, node_name, record)
    }

    scheduler.graph.successors
    |> Map.get(node_name, [])
    |> Enum.filter(&Map.has_key?(scheduler.graph.nodes_by_name, &1))
    |> Enum.reduce(scheduler, &release/2)
  end

  @doc "Records a failed attempt, then reserves a retry or halts the graph."
  @spec fail(
          scheduler :: t(),
          node_name :: Node.name(),
          record :: Record.t(),
          retry :: Retry.t()
        ) :: {:retry, pos_integer(), t()} | {:halt, t()}
  def fail(
        %__MODULE__{} = scheduler,
        node_name,
        %Record{status: :error, result: %Error{} = error} = record,
        %Retry{} = retry
      ) do
    ordinal = Map.fetch!(scheduler.attempts, node_name)

    scheduler = %__MODULE__{
      scheduler
      | running: MapSet.delete(scheduler.running, node_name),
        records: Map.put(scheduler.records, node_name, record)
    }

    if error.retryable? and ordinal < retry.max_attempts do
      next = ordinal + 1

      scheduler = %__MODULE__{
        scheduler
        | attempts: Map.put(scheduler.attempts, node_name, next),
          retrying: MapSet.put(scheduler.retrying, node_name)
      }

      {:retry, next, scheduler}
    else
      {:halt, halt(scheduler, node_name, record, ordinal)}
    end
  end

  @doc "Returns true when all graph nodes have final records or the graph halted."
  @spec done?(t()) :: boolean()
  def done?(%__MODULE__{halted?: true}), do: true

  def done?(%__MODULE__{} = scheduler) do
    map_size(scheduler.records) == map_size(scheduler.graph.nodes_by_name) and
      scheduler.ready == [] and MapSet.size(scheduler.running) == 0 and
      MapSet.size(scheduler.retrying) == 0
  end

  @doc "Returns true when a terminal failure halted the scheduler."
  @spec halted?(t()) :: boolean()
  def halted?(%__MODULE__{halted?: halted?}), do: halted?

  @doc "Gives the latest final graph-node record for each node."
  @spec records(t()) :: %{Node.name() => Record.t()}
  def records(%__MODULE__{records: records}), do: records

  @doc "Gives the sorted names classified as cancelled by a terminal failure."
  @spec cancelled(t()) :: [Node.name()]
  def cancelled(%__MODULE__{cancelled: cancelled}), do: cancelled

  @doc "Gives the sorted names classified as skipped by a terminal failure."
  @spec skipped(t()) :: [Node.name()]
  def skipped(%__MODULE__{skipped: skipped}), do: skipped

  @spec release(node_name :: Node.name(), scheduler :: t()) :: t()
  defp release(node_name, %__MODULE__{} = scheduler) do
    count = Map.fetch!(scheduler.pending, node_name) - 1
    pending = Map.put(scheduler.pending, node_name, count)

    if count == 0 and not Map.has_key?(scheduler.records, node_name) do
      %__MODULE__{scheduler | pending: pending, ready: insert_sorted(scheduler.ready, node_name)}
    else
      %__MODULE__{scheduler | pending: pending}
    end
  end

  @spec insert_sorted(names :: [Node.name()], node_name :: Node.name()) :: [Node.name()]
  defp insert_sorted(names, node_name), do: [node_name | names] |> Enum.uniq() |> Enum.sort()

  @spec halt(
          scheduler :: t(),
          failed_node :: Node.name(),
          failed_record :: Record.t(),
          failed_ordinal :: pos_integer()
        ) :: t()
  defp halt(%__MODULE__{} = scheduler, failed_node, %Record{} = failed_record, failed_ordinal) do
    cancelled =
      scheduler.running
      |> MapSet.union(scheduler.retrying)
      |> MapSet.delete(failed_node)
      |> Enum.sort()

    final_names = scheduler.records |> Map.keys() |> MapSet.new()
    cancelled_names = MapSet.new(cancelled)

    skipped =
      scheduler.graph.nodes_by_name
      |> Map.keys()
      |> MapSet.new()
      |> MapSet.difference(final_names)
      |> MapSet.difference(cancelled_names)
      |> Enum.sort()

    base_attempt = failed_record.job.attempt - failed_ordinal + 1

    records =
      Enum.reduce(cancelled, scheduler.records, fn name, records ->
        Map.put(
          records,
          name,
          classified_record(scheduler, name, failed_record.job, base_attempt, :cancelled)
        )
      end)

    records =
      Enum.reduce(skipped, records, fn name, records ->
        Map.put(
          records,
          name,
          classified_record(scheduler, name, failed_record.job, base_attempt, :skipped)
        )
      end)

    %__MODULE__{
      scheduler
      | halted?: true,
        ready: [],
        running: MapSet.new(),
        retrying: MapSet.new(),
        records: records,
        cancelled: cancelled,
        skipped: skipped
    }
  end

  @spec classified_record(
          scheduler :: t(),
          node_name :: Node.name(),
          failed_job :: Job.t(),
          base_attempt :: pos_integer(),
          status :: :cancelled | :skipped
        ) :: Record.t()
  defp classified_record(
         %__MODULE__{} = scheduler,
         node_name,
         %Job{} = failed_job,
         base_attempt,
         status
       ) do
    ordinal = Map.fetch!(scheduler.attempts, node_name)
    job = Job.at_attempt(failed_job, base_attempt + ordinal - 1)

    Record.new(%{job: job, node: node_name, status: status})
  end
end
