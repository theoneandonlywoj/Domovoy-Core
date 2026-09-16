defmodule DomovoyCore.Type do
  @moduledoc """
  The behaviour of a module that checks one kind of value.

  A type is an `Ecto.Type`. `use DomovoyCore.Type` gives the module `use Ecto.Type`,
  a `cast/1` that Ecto calls, a `dump/1` and a `load/1`. The module writes two
  functions of its own:

    * `type/0` — the Ecto primitive that the value is stored as, such as
      `:string` or `:map`.
    * `cast/2` — checks a raw value. It gets the metadata of the value, and it
      may give metadata back.

  `cast/2` gives one of four results:

    * `{:ok, value}` — the value is correct.
    * `{:ok, value, metadata}` — the value is correct, and the type adds
      `metadata` to the metadata of the value.
    * `:error` — the value is not correct.
    * `{:error, keyword}` — the value is not correct, and `keyword` says why.
      The keyword holds names, paths and keys. It never holds the value. See
      the redaction rule of `DomovoyCore.Error`.

  A type never builds a `DomovoyCore.Value`. `DomovoyCore.Value.cast/3` is the one
  constructor, and it calls `cast/2`.

  `dump/1` and `load/1` translate the value to the document the store keeps,
  and back. The default `dump/1` calls `document/1`: string keys at every
  depth, and a string for each atom. The default `load/1` gives the document
  as it is. A type whose value holds atom keys, atoms, a struct or a tuple
  writes its own `load/1`, so that a value read from a file equals the value
  that was written.

  ## Examples

  A type that reads and produces metadata:

      iex> defmodule MyApp.Type.Celsius do
      ...>   use DomovoyCore.Type
      ...>   @impl Ecto.Type
      ...>   def type, do: :integer
      ...>   @impl DomovoyCore.Type
      ...>   def cast(raw, %{"unit" => "fahrenheit"}) when is_number(raw),
      ...>     do: {:ok, round((raw - 32) * 5 / 9), %{"unit" => "celsius"}}
      ...>   def cast(raw, _metadata) when is_number(raw), do: {:ok, raw}
      ...>   def cast(_raw, _metadata), do: :error
      ...> end
      iex> MyApp.Type.Celsius.cast(212, %{"unit" => "fahrenheit"})
      {:ok, 100, %{"unit" => "celsius"}}
      iex> MyApp.Type.Celsius.cast(212)
      {:ok, 212}
      iex> MyApp.Type.Celsius.cast("hot")
      :error
      iex> MyApp.Type.Celsius.dump(100)
      {:ok, 100}
      iex> DomovoyCore.Type.type?(MyApp.Type.Celsius)
      true
      iex> DomovoyCore.Type.type?(DomovoyCore.Name)
      false
  """

  @typedoc "A module that implements `DomovoyCore.Type`."
  @type t() :: module()

  @typedoc "The metadata of a value. The keys are strings."
  @type metadata() :: map()

  @typedoc "The result of `cast/2`."
  @type cast() :: {:ok, any()} | {:ok, any(), metadata()} | :error | {:error, keyword()}

  @doc """
  Checks `raw` and gives the value that a `DomovoyCore.Value` holds.

  `metadata` is the metadata of the value. The type may read it, and it may
  give metadata back with `{:ok, value, metadata}`.
  """
  @callback cast(raw :: any(), metadata :: metadata()) :: cast()

  @doc """
  Gives the module `use Ecto.Type`, the `DomovoyCore.Type` behaviour, a `cast/1`
  for Ecto, a `dump/1` that calls `document/1`, and an identity `load/1`.

  `dump/1` and `load/1` are overridable. A type whose value holds atom keys,
  atoms, a struct or a tuple writes its own `load/1`, because the document
  that `document/1` gives holds strings where the value held atoms.
  """
  defmacro __using__(_opts) do
    quote do
      use Ecto.Type

      @behaviour DomovoyCore.Type

      @impl Ecto.Type
      def cast(raw), do: raw |> cast(%{}) |> DomovoyCore.Type.drop_metadata()

      @impl Ecto.Type
      def dump(value), do: DomovoyCore.Type.document(value)

      @impl Ecto.Type
      def load(value), do: {:ok, value}

      defoverridable dump: 1, load: 1
    end
  end

  @doc """
  Translates `term` to what JSON can hold.

  A binary, a number, a boolean and `nil` stay as they are. An atom becomes a
  string. A `DateTime` becomes an ISO 8601 string. A map gets string keys at
  every depth. A list keeps its order. Any other struct, a tuple, a pid, a
  function or a reference gives `:error`, so a type whose value holds one of
  those writes its own `dump/1`.

  ## Examples

      iex> DomovoyCore.Type.document(%{overall: :pass, steps: [%{name: :format}]})
      {:ok, %{"overall" => "pass", "steps" => [%{"name" => "format"}]}}

      iex> DomovoyCore.Type.document([1, "two", nil, true, ~U[2026-09-13 10:00:00Z]])
      {:ok, [1, "two", nil, true, "2026-09-13T10:00:00Z"]}

      iex> DomovoyCore.Type.document({:ok, 1})
      :error

      iex> DomovoyCore.Type.document(%{nested: {:ok, 1}})
      :error
  """
  @spec document(term :: any()) :: {:ok, any()} | :error
  def document(term) do
    {:ok, document!(term)}
  catch
    :not_a_document -> :error
  end

  @spec document!(term :: any()) :: any()
  defp document!(term)
       when is_binary(term) or is_number(term) or is_boolean(term) or is_nil(term),
       do: term

  defp document!(term) when is_atom(term), do: Atom.to_string(term)
  defp document!(%DateTime{} = term), do: DateTime.to_iso8601(term)
  defp document!(term) when is_list(term), do: Enum.map(term, &document!/1)

  defp document!(term) when is_map(term) and not is_struct(term) do
    Map.new(term, fn {key, value} -> {document_key!(key), document!(value)} end)
  end

  defp document!(_term), do: throw(:not_a_document)

  @spec document_key!(key :: any()) :: String.t()
  defp document_key!(key) when is_binary(key), do: key
  defp document_key!(key) when is_atom(key), do: Atom.to_string(key)
  defp document_key!(_key), do: throw(:not_a_document)

  @doc """
  Gives `document` back with each string key in `keys` as the atom.

  A `load/1` of a type with atom keys calls this on the document and then
  casts the result, so the value that comes back is the value that was
  written. Every other key stays as it is. A term that is not a map comes
  back as it is, so the cast can refuse it.

  ## Examples

      iex> DomovoyCore.Type.atom_keys(%{"id" => "u1", "name" => "Dev", "extra" => 1}, [:id, :name])
      %{"extra" => 1, id: "u1", name: "Dev"}

      iex> DomovoyCore.Type.atom_keys("not a map", [:id])
      "not a map"
  """
  @spec atom_keys(document :: any(), keys :: [atom()]) :: any()
  def atom_keys(document, keys) when is_map(document) and is_list(keys) do
    names = Map.new(keys, &{Atom.to_string(&1), &1})

    Map.new(document, fn {key, value} -> {Map.get(names, key, key), value} end)
  end

  def atom_keys(document, keys) when is_list(keys), do: document

  @doc """
  Reads the ISO 8601 string that `document/1` wrote for a `DateTime`.

  `nil` gives `{:ok, nil}`. A string that is not a time, or another term,
  gives `:error`.

  ## Examples

      iex> DomovoyCore.Type.datetime("2026-09-13T10:00:00Z")
      {:ok, ~U[2026-09-13 10:00:00Z]}

      iex> DomovoyCore.Type.datetime(nil)
      {:ok, nil}

      iex> DomovoyCore.Type.datetime("yesterday")
      :error
  """
  @spec datetime(document :: any()) :: {:ok, DateTime.t() | nil} | :error
  def datetime(nil), do: {:ok, nil}

  def datetime(document) when is_binary(document) do
    case DateTime.from_iso8601(document) do
      {:ok, time, _offset} -> {:ok, time}
      {:error, _reason} -> :error
    end
  end

  def datetime(_document), do: :error

  @doc """
  Loads each document of `documents` with `load`, in order.

  A `load/1` of a type whose value holds a list of another type calls this
  with the `load/1` of that type. The first `:error` stops the walk. A term
  that is not a list gives `:error`.

  ## Examples

      iex> DomovoyCore.Type.load_each([1, 2], &{:ok, &1 * 2})
      {:ok, [2, 4]}

      iex> DomovoyCore.Type.load_each([1, 2], fn _ -> :error end)
      :error

      iex> DomovoyCore.Type.load_each(%{}, &{:ok, &1})
      :error
  """
  @spec load_each(documents :: any(), load :: (any() -> {:ok, any()} | :error)) ::
          {:ok, [any()]} | :error
  def load_each(documents, load) when is_list(documents) and is_function(load, 1) do
    documents
    |> Enum.reduce_while({:ok, []}, fn document, {:ok, loaded} ->
      case load.(document) do
        {:ok, value} -> {:cont, {:ok, [value | loaded]}}
        :error -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, loaded} -> {:ok, Enum.reverse(loaded)}
      :error -> :error
    end
  end

  def load_each(_documents, load) when is_function(load, 1), do: :error

  @doc """
  Turns a result of `cast/2` into a result of `Ecto.Type.cast/1`.

  Ecto knows no metadata, so `{:ok, value, metadata}` becomes `{:ok, value}`.
  Every other result stays as it is.

  ## Examples

      iex> DomovoyCore.Type.drop_metadata({:ok, 1, %{"unit" => "celsius"}})
      {:ok, 1}
      iex> DomovoyCore.Type.drop_metadata({:ok, 1})
      {:ok, 1}
      iex> DomovoyCore.Type.drop_metadata(:error)
      :error
  """
  @spec drop_metadata(result :: cast()) :: {:ok, any()} | :error | {:error, keyword()}
  def drop_metadata({:ok, value, _metadata}), do: {:ok, value}
  def drop_metadata(result), do: result

  @doc """
  Returns `true` when `module` is loaded and implements `DomovoyCore.Type`.

  `DomovoyCore.Value.cast/3` refuses a module for which this is `false`, and
  `DomovoyCore.Value.load/1` refuses a module name from a file for which this is
  `false`. The store therefore never builds a value of an arbitrary module.
  """
  @spec type?(module :: module()) :: boolean()
  def type?(module) when is_atom(module) do
    Code.ensure_loaded?(module) and
      module.module_info(:attributes)
      |> Keyword.get_values(:behaviour)
      |> List.flatten()
      |> Enum.member?(DomovoyCore.Type)
  end

  def type?(_other), do: false
end
