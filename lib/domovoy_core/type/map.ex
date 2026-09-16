defmodule DomovoyCore.Type.Map do
  @moduledoc """
  `DomovoyCore.Type` for a map.

  This type accepts every map. The keys may be atoms or strings. `dump/1` is
  `DomovoyCore.Type.document/1`. It changes each atom key into a string, at every
  depth, so the stored form is a JSON object. `load/1` gives the stored form
  back as it is. A map with atom keys therefore comes back with string keys.

  ## Examples

      iex> DomovoyCore.Type.Map.cast(%{"count" => 1})
      {:ok, %{"count" => 1}}

      iex> DomovoyCore.Type.Map.cast([count: 1])
      :error

      iex> DomovoyCore.Type.Map.dump(%{count: 1, nested: %{deep: true}})
      {:ok, %{"count" => 1, "nested" => %{"deep" => true}}}

      iex> DomovoyCore.Type.Map.load(%{"count" => 1})
      {:ok, %{"count" => 1}}
  """

  use DomovoyCore.Type

  @impl Ecto.Type
  def type, do: :map

  @impl DomovoyCore.Type
  @spec cast(raw :: any(), metadata :: DomovoyCore.Type.metadata()) :: DomovoyCore.Type.cast()
  def cast(raw, _metadata) when is_map(raw) and not is_struct(raw), do: {:ok, raw}
  def cast(_raw, _metadata), do: :error
end
