defmodule DomovoyCore.Binding do
  @moduledoc """
  Names the node that supplies a bound value.

  Every binding carries the type its consumer expects. A node writes one as `{source, type}` in `bind`.
  `DomovoyCore.Node.new/1` turns that tuple into this struct. It checks the node name and the type.

  ## Examples

      node = DomovoyCore.Node.new(%{name: "delay", runner: MyApp.Runner.Delay, type: DomovoyCore.Type.Integer,
        bind: %{min_delay_ms: {"count", DomovoyCore.Type.Integer}}})
      node.bind.min_delay_ms
      %DomovoyCore.Binding{from: "count", type: DomovoyCore.Type.Integer, metadata: %{}}
  """

  alias DomovoyCore.Name
  alias DomovoyCore.Type

  @enforce_keys [:from, :type]
  defstruct [:from, :type, metadata: %{}]

  @type t() :: %__MODULE__{
          from: Name.t(),
          type: Type.t(),
          metadata: map()
        }

  # Checks the source name with `DomovoyCore.Name`.
  # `DomovoyCore.Node.new/1` is the caller; it turns the raised `ArgumentError` into its own diagnostic.
  @doc false
  @spec new(source :: String.t(), type :: Type.t()) :: t()
  def new(source, type) when is_binary(source) do
    Name.check!(source)

    unless Type.type?(type),
      do: raise(ArgumentError, "binding type must implement DomovoyCore.Type")

    %__MODULE__{from: source, type: type}
  end

  def new(_source, _type), do: raise(ArgumentError, "binding source must be a string")
end
