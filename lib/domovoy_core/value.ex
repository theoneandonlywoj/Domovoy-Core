defmodule DomovoyCore.Value do
  @moduledoc """
  A struct that holds a raw value and its `DomovoyCore.Type` module.

  A `DomovoyCore.Value` is the unit that moves through the system. It moves from
  the runner that makes it, through the store, to the nodes that read it.

  The struct keeps three items. `:value` is the raw value. `:type` is the
  module that checked it. `:metadata` is a map with string keys that the core
  never reads.

  `cast/3` is the one way to make a `DomovoyCore.Value`. It always calls the
  `cast/2` of the type, so no code labels a term with a type that did not
  check it. `dump/1` and `load/1` translate a value to the document that a
  store keeps, and back.

  ## Examples

      iex> DomovoyCore.Value.cast(42, DomovoyCore.Type.Integer)
      {:ok, %DomovoyCore.Value{value: 42, type: DomovoyCore.Type.Integer, metadata: %{}}}

      iex> DomovoyCore.Value.cast("42", DomovoyCore.Type.Integer)
      {:error, %DomovoyCore.Error{type: :cast_error, reason: %{module: DomovoyCore.Type.Integer}}}

      iex> DomovoyCore.Value.cast!(42, DomovoyCore.Type.Integer, %{"source" => "test"})
      %DomovoyCore.Value{value: 42, type: DomovoyCore.Type.Integer, metadata: %{"source" => "test"}}

      iex> DomovoyCore.Value.cast(42, DomovoyCore.Name)
      ** (ArgumentError) DomovoyCore.Name is not a DomovoyCore.Type

  A value dumps to a document with a version, and loads back from it:

      iex> value = DomovoyCore.Value.cast!("main", DomovoyCore.Type.String)
      iex> {:ok, document} = DomovoyCore.Value.dump(value)
      iex> document
      %{
        "version" => 1,
        "type" => "Elixir.DomovoyCore.Type.String",
        "value" => "main",
        "metadata" => %{}
      }
      iex> DomovoyCore.Value.load(document)
      {:ok, %DomovoyCore.Value{value: "main", type: DomovoyCore.Type.String, metadata: %{}}}

  `load/1` refuses a version it does not know, and a module that is not a
  type:

      iex> DomovoyCore.Value.load(%{"version" => 2, "type" => "Elixir.DomovoyCore.Type.String", "value" => "main", "metadata" => %{}})
      {:error, %DomovoyCore.Error{type: :unsupported_version, reason: %{version: 2, supported: [1]}}}

      iex> DomovoyCore.Value.load(%{"version" => 1, "type" => "Elixir.DomovoyCore.Name", "value" => %{}, "metadata" => %{}})
      {:error, %DomovoyCore.Error{type: :not_a_type, reason: %{module: "Elixir.DomovoyCore.Name"}}}
  """

  alias DomovoyCore.Error
  alias DomovoyCore.Type
  alias DomovoyCore.Value

  @version 1

  @typedoc "A raw value with the type that checked it and its metadata."
  @type t() :: %Value{
          value: any(),
          type: Type.t(),
          metadata: Type.metadata()
        }

  @typedoc "The document that `dump/1` gives and `load/1` takes."
  @type document() :: %{
          required(String.t()) => any()
        }

  defstruct value: nil,
            type: nil,
            metadata: %{}

  @doc """
  Casts `raw` with `type` and gives a `DomovoyCore.Value`.

  `metadata` is the metadata of the value. The type reads it, and the metadata
  the type gives back is merged over it. A raw value that the type refuses
  gives `DomovoyCore.Error.cast_error/3`.

  Raises an `ArgumentError` when `type` is not a module that implements
  `DomovoyCore.Type`.
  """
  @spec cast(raw :: any(), type :: Type.t(), metadata :: Type.metadata()) ::
          {:ok, t()} | {:error, Error.t()}
  def cast(raw, type, metadata \\ %{}) when is_map(metadata) do
    check_type!(type)

    case type.cast(raw, metadata) do
      {:ok, value} ->
        {:ok, %Value{value: value, type: type, metadata: metadata}}

      {:ok, value, produced} ->
        {:ok, %Value{value: value, type: type, metadata: Map.merge(metadata, produced)}}

      :error ->
        {:error, Error.cast_error(raw, type)}

      {:error, details} ->
        {:error, Error.cast_error(raw, type, details)}
    end
  end

  @doc """
  Casts `raw` with `type` and gives the `DomovoyCore.Value`, or raises an
  `ArgumentError` with the message of the error.
  """
  @spec cast!(raw :: any(), type :: Type.t(), metadata :: Type.metadata()) :: t()
  def cast!(raw, type, metadata \\ %{}) do
    case cast(raw, type, metadata) do
      {:ok, value} -> value
      {:error, error} -> raise ArgumentError, Error.message(error)
    end
  end

  @doc """
  Takes the result of `cast/3` out of its tuple.

  A function that gives a `DomovoyCore.Value` or a `DomovoyCore.Error`, as a runner
  does, pipes `cast/3` into this.

  ## Examples

      iex> 42 |> DomovoyCore.Value.cast(DomovoyCore.Type.Integer) |> DomovoyCore.Value.unwrap()
      %DomovoyCore.Value{value: 42, type: DomovoyCore.Type.Integer, metadata: %{}}

      iex> "42" |> DomovoyCore.Value.cast(DomovoyCore.Type.Integer) |> DomovoyCore.Value.unwrap()
      %DomovoyCore.Error{type: :cast_error, reason: %{module: DomovoyCore.Type.Integer}}
  """
  @spec unwrap(result :: {:ok, t()} | {:error, Error.t()}) :: t() | Error.t()
  def unwrap({:ok, %Value{} = value}), do: value
  def unwrap({:error, %Error{} = error}), do: error

  @doc """
  Translates `value` to the document that a store keeps.

  The document holds `"version"`, the name of the type module, the value as
  `dump/1` of the type gives it, and the metadata.
  """
  @spec dump(value :: t()) :: {:ok, document()} | {:error, Error.t()}
  def dump(%Value{value: value, type: type, metadata: metadata}) do
    case type.dump(value) do
      {:ok, dumped} ->
        {:ok,
         %{
           "version" => @version,
           "type" => Atom.to_string(type),
           "value" => dumped,
           "metadata" => metadata
         }}

      :error ->
        {:error, Error.dump_error(type)}
    end
  end

  @doc """
  Translates a document that `dump/1` gave back to a `DomovoyCore.Value`.

  A `"version"` other than `#{@version}` gives `DomovoyCore.Error.unsupported_version/1`.
  A `"type"` that names no loaded module, or a module that does not implement
  `DomovoyCore.Type`, gives `DomovoyCore.Error.not_a_type/1`. A value that `load/1` of
  the type refuses, with `:error` or with `{:error, keyword}` from the
  `cast/2` that a `load/1` ends in, gives `DomovoyCore.Error.load_error/1`.
  """
  @spec load(document :: any()) :: {:ok, t()} | {:error, Error.t()}
  def load(%{"version" => @version, "type" => name, "value" => dumped} = document)
      when is_binary(name) do
    with {:ok, type} <- type_module(name),
         {:ok, value} <- load_value(type, dumped) do
      {:ok, %Value{value: value, type: type, metadata: Map.get(document, "metadata", %{})}}
    end
  end

  def load(%{"version" => version}), do: {:error, Error.unsupported_version(version)}
  def load(_document), do: {:error, Error.unsupported_version(nil)}

  @spec check_type!(type :: any()) :: :ok
  defp check_type!(type) do
    if Type.type?(type),
      do: :ok,
      else: raise(ArgumentError, "#{inspect(type)} is not a DomovoyCore.Type")
  end

  @spec type_module(name :: String.t()) :: {:ok, Type.t()} | {:error, Error.t()}
  defp type_module(name) do
    module = String.to_existing_atom(name)

    if Type.type?(module), do: {:ok, module}, else: {:error, Error.not_a_type(name)}
  rescue
    ArgumentError -> {:error, Error.not_a_type(name)}
  end

  @spec load_value(type :: Type.t(), dumped :: any()) :: {:ok, any()} | {:error, Error.t()}
  defp load_value(type, dumped) do
    case type.load(dumped) do
      {:ok, value} -> {:ok, value}
      :error -> {:error, Error.load_error(type)}
      {:error, _details} -> {:error, Error.load_error(type)}
    end
  end
end
