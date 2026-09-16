defmodule DomovoyCore.Runtime do
  @moduledoc """
  Caller-supervised process infrastructure for DomovoyCore.

  Add a named runtime to a supervision tree:

      children = [
        {DomovoyCore.Runtime, name: MyDomovoy}
      ]

  The name is also the runtime reference passed to `DomovoyCore.Run` and
  `DomovoyCore.Workflow.Server`. Multiple names create fully isolated runtime
  instances in the same VM.

  ## Options

    * `:name` - required atom used to name the runtime supervisor.
    * `:workflow_task_max_children` - workflow step task limit; defaults to `100`.
    * `:workflow_server_max_children` - workflow server limit; defaults to `500`.
  """

  @type ref() :: atom()

  @doc "Returns a child specification whose id is unique to the runtime name."
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) when is_list(opts) do
    name = name!(opts)

    %{
      id: {__MODULE__, name},
      start: {__MODULE__, :start_link, [opts]},
      type: :supervisor
    }
  end

  @doc "Starts a named runtime supervisor."
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts) when is_list(opts) do
    name = name!(opts)
    workflow_task_max_children = limit!(opts, :workflow_task_max_children, 100)
    workflow_server_max_children = limit!(opts, :workflow_server_max_children, 500)

    children = [
      {Phoenix.PubSub, name: pubsub(name)},
      {Registry, keys: :unique, name: workflow_registry(name)},
      Supervisor.child_spec(
        {Task.Supervisor, name: engine_task_supervisor(name)},
        id: :engine_task_supervisor
      ),
      Supervisor.child_spec(
        {Task.Supervisor,
         name: workflow_task_supervisor(name), max_children: workflow_task_max_children},
        id: :workflow_task_supervisor
      ),
      {DynamicSupervisor,
       name: workflow_supervisor(name),
       strategy: :one_for_one,
       max_children: workflow_server_max_children}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: name)
  end

  @doc false
  @spec pubsub(ref()) :: atom()
  def pubsub(runtime), do: component(runtime, PubSub)

  @doc false
  @spec workflow_registry(ref()) :: atom()
  def workflow_registry(runtime), do: component(runtime, WorkflowRegistry)

  @doc false
  @spec engine_task_supervisor(ref()) :: atom()
  def engine_task_supervisor(runtime), do: component(runtime, EngineTaskSupervisor)

  @doc false
  @spec workflow_task_supervisor(ref()) :: atom()
  def workflow_task_supervisor(runtime), do: component(runtime, WorkflowTaskSupervisor)

  @doc false
  @spec workflow_supervisor(ref()) :: atom()
  def workflow_supervisor(runtime), do: component(runtime, WorkflowSupervisor)

  @spec component(ref(), atom()) :: atom()
  defp component(runtime, suffix) when is_atom(runtime), do: Module.concat(runtime, suffix)

  @spec name!(keyword()) :: ref()
  defp name!(opts) do
    case Keyword.fetch(opts, :name) do
      {:ok, name} when is_atom(name) and not is_nil(name) -> name
      {:ok, other} -> raise ArgumentError, "runtime name must be an atom, got: #{inspect(other)}"
      :error -> raise ArgumentError, "missing required :name option"
    end
  end

  @spec limit!(keyword(), atom(), pos_integer()) :: pos_integer()
  defp limit!(opts, key, default) do
    case Keyword.get(opts, key, default) do
      value when is_integer(value) and value > 0 -> value
      other -> raise ArgumentError, "#{key} must be a positive integer, got: #{inspect(other)}"
    end
  end
end
