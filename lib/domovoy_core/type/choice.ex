defmodule DomovoyCore.Type.Choice do
  @moduledoc """
  `DomovoyCore.Type` for the answer of a person to a `DomovoyCore.Decision`.

  The raw value is a `%DomovoyCore.Choice{}` with a `name` that is not empty and
  a `description` that is not empty. The type does not check that a Decision
  offers the choice, because a type does not know the Decision.
  `DomovoyCore.Decision.answer/2` does that check.

  `dump/1` gives a document with the name, the description, the target, the
  typed inputs and the metadata. A target `{:run, "implement"}` becomes
  `%{"kind" => "run", "vertex" => "implement"}`, and `:halt` becomes
  `"halt"`. A type module in `inputs` becomes its name. `load/1` makes the
  `%DomovoyCore.Choice{}` again with `DomovoyCore.Choice.new/1`.

  ## Examples

  A choice with a name and a description casts. A choice with an empty
  description gives an error:

      iex> choice = DomovoyCore.Choice.new(%{
      ...>   name: "proceed",
      ...>   description: "The plan is correct. DomovoyCore implements it.",
      ...>   target: {:run, "implement"}
      ...> })
      iex> DomovoyCore.Value.cast(choice, DomovoyCore.Type.Choice)
      {:ok,
       %DomovoyCore.Value{
         value: %DomovoyCore.Choice{
           name: "proceed",
           description: "The plan is correct. DomovoyCore implements it.",
           target: {:run, "implement"},
           inputs: %{},
           metadata: %{}
         },
         type: DomovoyCore.Type.Choice,
         metadata: %{}
       }}
      iex> DomovoyCore.Value.cast(%{choice | description: ""}, DomovoyCore.Type.Choice)
      {:error,
       %DomovoyCore.Error{
         type: :cast_error,
         reason: %{
           module: DomovoyCore.Type.Choice,
           keys: [:description, :inputs, :metadata, :name, :target]
         }
       }}

  A value that is not a choice gives an error too:

      iex> DomovoyCore.Type.Choice.cast("proceed")
      :error

  `dump/1` and `load/1` round-trip a choice with typed inputs through a
  document:

      iex> choice = DomovoyCore.Choice.new(%{
      ...>   name: "revise",
      ...>   description: "Say what to change.",
      ...>   target: {:rerun, "plan"},
      ...>   inputs: %{"plan_context" => DomovoyCore.Type.String},
      ...>   metadata: %{"shortcut" => "r"}
      ...> })
      iex> {:ok, document} = DomovoyCore.Type.Choice.dump(choice)
      iex> document
      %{
        "name" => "revise",
        "description" => "Say what to change.",
        "target" => %{"kind" => "rerun", "vertex" => "plan"},
        "inputs" => %{"plan_context" => "Elixir.DomovoyCore.Type.String"},
        "metadata" => %{"shortcut" => "r"}
      }
      iex> DomovoyCore.Type.Choice.load(document)
      {:ok, choice}

      iex> DomovoyCore.Type.Choice.load(%{"name" => "stop"})
      :error

      iex> DomovoyCore.Type.Choice.load(%{
      ...>   "name" => "revise",
      ...>   "description" => "Say what to change.",
      ...>   "target" => "halt",
      ...>   "inputs" => %{"plan_context" => "Elixir.DomovoyCore.Name"}
      ...> })
      :error
  """

  use DomovoyCore.Type

  alias DomovoyCore.Choice
  alias DomovoyCore.Type

  @impl Ecto.Type
  def type, do: :map

  @impl DomovoyCore.Type
  @spec cast(raw :: any(), metadata :: DomovoyCore.Type.metadata()) :: DomovoyCore.Type.cast()
  def cast(%Choice{name: name, description: description} = choice, _metadata)
      when is_binary(name) and name != "" and is_binary(description) and description != "" do
    {:ok, choice}
  end

  def cast(_raw, _metadata), do: :error

  @impl Ecto.Type
  @spec dump(choice :: Choice.t()) :: {:ok, map()} | :error
  def dump(%Choice{
        name: name,
        description: description,
        target: target,
        inputs: inputs,
        metadata: metadata
      }) do
    with {:ok, metadata_document} <- Type.document(metadata),
         {:ok, inputs_document} <- Type.document(inputs) do
      {:ok,
       %{
         "name" => name,
         "description" => description,
         "target" => dump_target(target),
         "inputs" => inputs_document,
         "metadata" => metadata_document
       }}
    end
  end

  def dump(_other), do: :error

  @impl Ecto.Type
  @spec load(document :: any()) :: {:ok, Choice.t()} | :error
  def load(%{"name" => name, "description" => description, "target" => target} = document)
      when is_binary(name) and is_binary(description) do
    with {:ok, target} <- load_target(target),
         {:ok, inputs} <- load_inputs(Map.get(document, "inputs", %{})) do
      {:ok,
       Choice.new(%{
         name: name,
         description: description,
         target: target,
         inputs: inputs,
         metadata: Map.get(document, "metadata", %{})
       })}
    end
  end

  def load(_document), do: :error

  @spec load_inputs(document :: any()) :: {:ok, Choice.inputs()} | :error
  defp load_inputs(document) when is_map(document) do
    document
    |> Enum.reduce_while({:ok, %{}}, fn {name, module_name}, {:ok, inputs} ->
      case load_module(module_name) do
        {:ok, module} -> {:cont, {:ok, Map.put(inputs, name, module)}}
        :error -> {:halt, :error}
      end
    end)
  end

  defp load_inputs(_document), do: :error

  @spec load_module(name :: any()) :: {:ok, Type.t()} | :error
  defp load_module(name) when is_binary(name) do
    module = String.to_existing_atom(name)

    if Type.type?(module), do: {:ok, module}, else: :error
  rescue
    ArgumentError -> :error
  end

  defp load_module(_name), do: :error

  @spec dump_target(target :: Choice.target()) :: String.t() | map()
  defp dump_target(:halt), do: "halt"
  defp dump_target({kind, vertex}), do: %{"kind" => Atom.to_string(kind), "vertex" => vertex}

  @spec load_target(document :: any()) :: {:ok, Choice.target()} | :error
  defp load_target("halt"), do: {:ok, :halt}

  defp load_target(%{"kind" => "run", "vertex" => vertex}) when is_binary(vertex),
    do: {:ok, {:run, vertex}}

  defp load_target(%{"kind" => "rerun", "vertex" => vertex}) when is_binary(vertex),
    do: {:ok, {:rerun, vertex}}

  defp load_target(_document), do: :error
end
