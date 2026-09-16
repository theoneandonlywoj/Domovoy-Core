defmodule DomovoyCore.Type.Any do
  @moduledoc """
  `DomovoyCore.Type` for any term.

  This type accepts every raw value. A node uses it when the shape of a value
  does not matter, and a binding of this type accepts the value of every
  producer. `dump/1` is `DomovoyCore.Type.document/1` and `load/1` gives the
  document as it is. A term that `document/1` refuses, such as a tuple, gives
  `DomovoyCore.Value.dump/1` a `dump_error`, so it does not survive a store on
  disk. A map with atom keys comes back with string keys.

  ## Examples

      iex> DomovoyCore.Type.Any.cast({:ok, 1})
      {:ok, {:ok, 1}}

      iex> DomovoyCore.Type.Any.cast(nil)
      {:ok, nil}

      iex> DomovoyCore.Type.Any.dump(%{count: 1})
      {:ok, %{"count" => 1}}

      iex> DomovoyCore.Type.Any.dump({:ok, 1})
      :error
  """

  use DomovoyCore.Type

  @impl Ecto.Type
  def type, do: :map

  @impl DomovoyCore.Type
  @spec cast(raw :: any(), metadata :: DomovoyCore.Type.metadata()) :: DomovoyCore.Type.cast()
  def cast(raw, _metadata), do: {:ok, raw}
end
