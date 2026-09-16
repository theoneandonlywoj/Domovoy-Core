defmodule DomovoyCore.Runner do
  @moduledoc """
  Defines a runner and its typed input contract.

  `use DomovoyCore.Runner` enables `input`, `required`, and `validators`. The input block defines an embedded Ecto schema without a primary key.
  The generated `Input` alias names that schema. `__domovoy_core__/1` exposes `:input`, `:required`, `:validators`, `:retry`, and `:extra?`.

  A runner receives its input struct and the `DomovoyCore.Context` of the attempt. It returns a raw
  value in a success tuple. The Engine casts the value through the node type. Runner validators
  precede node validators at execution time.

  ## Examples

      iex> defmodule Elixir.DomovoyCore.Example.CountRunner do
      ...>   use DomovoyCore.Runner, retry: [max_attempts: 2]
      ...>   input do
      ...>     field :count, DomovoyCore.Type.Integer
      ...>     field :label, DomovoyCore.Type.String, default: "items"
      ...>   end
      ...>   required [:count]
      ...>   @impl DomovoyCore.Runner
      ...>   def run(%Input{count: count}, %DomovoyCore.Context{}), do: {:ok, count}
      ...> end
      iex> DomovoyCore.Example.CountRunner.__domovoy_core__(:required)
      [:count]
      iex> changeset = DomovoyCore.Runner.changeset(DomovoyCore.Example.CountRunner, %{"count" => 3})
      iex> input = Ecto.Changeset.apply_changes(changeset)
      iex> Map.from_struct(input)
      %{count: 3, label: "items"}
      iex> DomovoyCore.Example.CountRunner.run(input, %DomovoyCore.Context{})
      {:ok, 3}
  """

  alias DomovoyCore.Context
  alias Ecto.Changeset

  @type result() :: {:ok, term()} | {:ok, term(), map()} | {:error, term()}

  @callback run(input :: struct(), context :: Context.t()) :: result()

  @doc """
  Enables the runner DSL. Options are `:retry` and `:extra?`.
  """
  defmacro __using__(options) do
    quote do
      @behaviour DomovoyCore.Runner
      import DomovoyCore.Runner, only: [input: 1, required: 1, validators: 1]
      @before_compile DomovoyCore.Runner
      @domovoy_core_required []
      @domovoy_core_validators []
      @domovoy_core_retry DomovoyCore.Retry.new(Keyword.get(unquote(options), :retry, []))
      @domovoy_core_extra Keyword.get(unquote(options), :extra?, false)
      unless is_boolean(@domovoy_core_extra),
        do: raise(ArgumentError, "runner extra? must be a boolean")
    end
  end

  @doc """
  Defines the generated input schema with Ecto `field` declarations.
  """
  defmacro input(do: block) do
    input = Module.concat(__CALLER__.module, "Input")

    quote do
      defmodule unquote(input) do
        @moduledoc false
        use Ecto.Schema
        @primary_key false
        embedded_schema do
          unquote(block)

          if Module.get_attribute(unquote(__CALLER__.module), :domovoy_core_extra) do
            field(:extra, DomovoyCore.Type.Map, default: %{})
          end
        end

        @type t() :: %__MODULE__{}
      end

      alias __MODULE__.Input
    end
  end

  @doc """
  Declares the input fields that must contain non-empty values.
  """
  defmacro required(fields) do
    quote do
      @domovoy_core_required unquote(fields)
    end
  end

  @doc """
  Declares runner validators in execution order.
  """
  defmacro validators(modules) do
    quote do
      @domovoy_core_validators unquote(modules)
    end
  end

  @doc false
  defmacro __before_compile__(env) do
    input = Module.concat(env.module, "Input")
    required = Module.get_attribute(env.module, :domovoy_core_required)
    validators = Module.get_attribute(env.module, :domovoy_core_validators)
    retry = Module.get_attribute(env.module, :domovoy_core_retry)
    extra? = Module.get_attribute(env.module, :domovoy_core_extra)

    check_input!(input)
    check_required!(required, input)
    check_validators!(validators)

    quote do
      @doc false
      @spec __domovoy_core__(atom()) :: module() | [atom()] | DomovoyCore.Retry.t() | boolean()
      def __domovoy_core__(:input), do: unquote(input)
      def __domovoy_core__(:required), do: unquote(required)
      def __domovoy_core__(:validators), do: unquote(validators)
      def __domovoy_core__(:retry), do: unquote(Macro.escape(retry))
      def __domovoy_core__(:extra?), do: unquote(extra?)
    end
  end

  @doc """
  Casts runner parameters and validates required fields.

  Known string keys become schema keys without new atoms. Duplicate atom and string keys give an error.
  If extras are enabled, unknown keys retain their original form under `:extra`. Unknown keys replace matching explicit extra entries.
  Otherwise, unknown keys give errors. Cast errors contain field names and types, never raw values or type error details.
  Validators run separately in the Engine. The changeset retains parameters for Ecto, so callers must report only its errors.
  """
  @spec changeset(runner :: module(), params :: map()) :: Changeset.t()
  def changeset(runner, params) when is_map(params) and not is_struct(params) do
    input = runner.__domovoy_core__(:input)
    fields = input.__schema__(:fields)
    names = Map.new(fields, &{Atom.to_string(&1), &1})
    {known, unknown, errors} = normalize_params(params, names)
    extra? = runner.__domovoy_core__(:extra?)
    known = if extra?, do: collect_extra(known, unknown), else: known

    changeset =
      input
      |> struct()
      |> Changeset.cast(known, fields, empty_values: [])

    errors =
      Enum.map(changeset.errors, fn {field, _error} ->
        {field, {"is invalid", [validation: :cast, type: input.__schema__(:type, field)]}}
      end) ++ errors

    changeset = %{changeset | errors: errors, valid?: errors == []}

    changeset =
      if extra? do
        changeset
      else
        unknown
        |> Map.keys()
        |> Enum.sort()
        |> Enum.reduce(changeset, fn field, acc ->
          Changeset.add_error(acc, :base, "unknown parameter", field: field)
        end)
      end

    changeset = Changeset.validate_required(changeset, runner.__domovoy_core__(:required))

    Enum.reduce(runner.__domovoy_core__(:required), changeset, &validate_non_blank_required/2)
  end

  def changeset(runner, _params) do
    runner.__domovoy_core__(:input)
    |> struct()
    |> Changeset.change()
    |> Changeset.add_error(:base, "parameters must be a map")
  end

  @spec check_input!(input :: module()) :: :ok
  defp check_input!(input) do
    unless Code.ensure_compiled(input) == {:module, input},
      do: raise(ArgumentError, "runner must declare an input block")

    :ok
  end

  @spec check_required!(required :: term(), input :: module()) :: :ok
  defp check_required!(required, input) do
    unless is_list(required) and Enum.all?(required, &(&1 in input.__schema__(:fields))),
      do: raise(ArgumentError, "runner required fields must name input fields")

    :ok
  end

  @spec check_validators!(validators :: term()) :: :ok
  defp check_validators!(validators) do
    unless is_list(validators) and Enum.all?(validators, &is_atom/1),
      do: raise(ArgumentError, "runner validators must be a list of modules")

    :ok
  end

  @spec validate_non_blank_required(field :: atom(), changeset :: Changeset.t()) ::
          Changeset.t()
  defp validate_non_blank_required(field, %Changeset{} = changeset) do
    value = Changeset.get_field(changeset, field)

    if is_binary(value) and String.trim(value) == "" and
         not Keyword.has_key?(changeset.errors, field) do
      Changeset.add_error(changeset, field, "can't be blank", validation: :required)
    else
      changeset
    end
  end

  @spec normalize_params(params :: map(), names :: map()) :: {map(), map(), keyword()}
  defp normalize_params(params, names) do
    params
    |> Enum.sort()
    |> Enum.reduce({%{}, %{}, []}, fn {key, value}, {known, unknown, errors} ->
      name = if is_atom(key), do: Atom.to_string(key), else: key

      cond do
        not (is_atom(key) or is_binary(key)) ->
          {known, unknown, [{:base, {"parameter keys must be atoms or strings", []}} | errors]}

        not Map.has_key?(names, name) ->
          {known, Map.put(unknown, key, value), errors}

        Map.has_key?(known, name) ->
          {known, unknown, [{Map.fetch!(names, name), {"has duplicate parameters", []}} | errors]}

        true ->
          {Map.put(known, name, value), unknown, errors}
      end
    end)
  end

  @spec collect_extra(known :: map(), unknown :: map()) :: map()
  defp collect_extra(known, unknown) do
    case Map.get(known, "extra", %{}) do
      extra when is_map(extra) and not is_struct(extra) ->
        Map.put(known, "extra", Map.merge(extra, unknown))

      _invalid ->
        known
    end
  end
end
