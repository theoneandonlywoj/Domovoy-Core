defmodule DomovoyCore.Type.String do
  @moduledoc """
  `DomovoyCore.Type` for a string.

  This type accepts every Elixir binary. This includes an empty string. A node
  that must refuse an empty string does that check in its own validation.

  ## Examples

      iex> DomovoyCore.Type.String.cast("main")
      {:ok, "main"}

      iex> DomovoyCore.Type.String.cast(42)
      :error

      iex> DomovoyCore.Value.cast("main", DomovoyCore.Type.String)
      {:ok, %DomovoyCore.Value{value: "main", type: DomovoyCore.Type.String, metadata: %{}}}
  """

  use DomovoyCore.Type

  @impl Ecto.Type
  def type, do: :string

  @impl DomovoyCore.Type
  @spec cast(raw :: any(), metadata :: DomovoyCore.Type.metadata()) :: DomovoyCore.Type.cast()
  def cast(raw, _metadata) when is_binary(raw), do: {:ok, raw}
  def cast(_raw, _metadata), do: :error
end
