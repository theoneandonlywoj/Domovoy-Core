defmodule DomovoyCore.Retry do
  @moduledoc """
  Holds the retry policy of a runner or node.

  A runner declares the default policy. Node options replace those defaults
  field by field.

  `max_attempts` counts executions during one `DomovoyCore.Engine.run/4` call.
  `backoff_ms` sets a fixed delay before each retry. A node uses no active task
  slot while it waits for this delay. `timeout_ms` limits each attempt, or
  `:infinity` disables the timeout.

  `DomovoyCore.Engine` retries only an error with `retryable?: true`. A timed-out
  attempt and an abnormal task exit give retryable errors. Input preparation
  errors and invalid runner results do not retry.

  ## Examples

      iex> DomovoyCore.Retry.new([])
      %DomovoyCore.Retry{max_attempts: 1, backoff_ms: 0, timeout_ms: :infinity, metadata: %{}}

      iex> defaults = DomovoyCore.Retry.new(max_attempts: 3, backoff_ms: 100)
      iex> DomovoyCore.Retry.new(%{timeout_ms: 500}, defaults)
      %DomovoyCore.Retry{max_attempts: 3, backoff_ms: 100, timeout_ms: 500, metadata: %{}}

      iex> DomovoyCore.Retry.new(max_attempts: 0)
      ** (ArgumentError) retry max_attempts must be a positive integer
  """

  defstruct max_attempts: 1, backoff_ms: 0, timeout_ms: :infinity, metadata: %{}

  @type t() :: %__MODULE__{
          max_attempts: pos_integer(),
          backoff_ms: non_neg_integer(),
          timeout_ms: :infinity | pos_integer(),
          metadata: map()
        }

  @doc """
  Applies options to defaults and validates the result.

  Options can be a keyword list, a map, or a complete policy. A complete
  policy replaces every default.

  Invalid options raise `ArgumentError`. Error messages contain no option
  values.
  """
  @spec new(options :: keyword() | map() | t(), defaults :: t()) :: t()
  def new(options, defaults \\ %__MODULE__{})

  def new(%__MODULE__{} = options, %__MODULE__{} = defaults),
    do: options |> Map.from_struct() |> new(defaults)

  def new(options, %__MODULE__{} = defaults) when is_list(options) do
    unless Keyword.keyword?(options),
      do: raise(ArgumentError, "retry options must be a keyword list or map")

    options |> Map.new() |> new(defaults)
  end

  def new(options, %__MODULE__{} = defaults) when is_map(options) and not is_struct(options) do
    options = validate_options!(options)
    _ = defaults |> Map.from_struct() |> validate_options!()
    struct!(defaults, options)
  end

  def new(_options, _defaults),
    do: raise(ArgumentError, "retry options must be a keyword list or map")

  @spec validate_options!(options :: map()) :: map()
  defp validate_options!(options) do
    Enum.each(options, fn {key, value} ->
      case key do
        :max_attempts -> validate_max_attempts!(value)
        :backoff_ms -> validate_backoff!(value)
        :timeout_ms -> validate_timeout!(value)
        :metadata -> validate_metadata!(value)
        _ -> raise ArgumentError, "retry options contain an unknown field"
      end
    end)

    options
  end

  @spec validate_max_attempts!(term()) :: :ok
  defp validate_max_attempts!(value) when is_integer(value) and value > 0, do: :ok

  defp validate_max_attempts!(_),
    do: raise(ArgumentError, "retry max_attempts must be a positive integer")

  @spec validate_backoff!(term()) :: :ok
  defp validate_backoff!(value) when is_integer(value) and value >= 0, do: :ok

  defp validate_backoff!(_),
    do: raise(ArgumentError, "retry backoff_ms must be a non-negative integer")

  @spec validate_timeout!(term()) :: :ok
  defp validate_timeout!(value) when value == :infinity or (is_integer(value) and value > 0),
    do: :ok

  defp validate_timeout!(_),
    do: raise(ArgumentError, "retry timeout_ms must be :infinity or a positive integer")

  @spec validate_metadata!(term()) :: :ok
  defp validate_metadata!(value) when is_map(value) and not is_struct(value), do: :ok

  defp validate_metadata!(_), do: raise(ArgumentError, "retry metadata must be a map")
end
