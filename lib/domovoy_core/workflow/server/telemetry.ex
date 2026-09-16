defmodule DomovoyCore.Workflow.Server.Telemetry do
  @moduledoc """
  The telemetry metadata of `DomovoyCore.Workflow.Server`.

  This module builds the maps that the server sends with each span. It holds
  no process and no state. The server keeps the callbacks, and this module
  keeps the shape of the metadata in one place.

  Every stop map holds `workflow`, `run_id`, `outcome`, `generation` and
  `cursor`. A `generation` or a `cursor` that the server does not know yet
  is `nil`. Every drive map also holds `vertex` and `kind`. A `cursor` that
  names no vertex gives `kind: :unknown`.
  """

  @typedoc "The metadata of a telemetry span."
  @type meta() :: %{atom() => any()}

  @doc """
  Gives the start metadata of a fresh run.

  ## Examples

      iex> DomovoyCore.Workflow.Server.Telemetry.start_meta("issue_to_pr", "dom-43", "prepare")
      %{workflow: "issue_to_pr", run_id: "dom-43", generation: 0, cursor: "prepare"}
  """
  @spec start_meta(
          workflow_name :: String.t(),
          run_id :: String.t(),
          cursor :: String.t() | nil
        ) :: meta()
  def start_meta(workflow_name, run_id, cursor)
      when is_binary(workflow_name) and is_binary(run_id) do
    %{workflow: workflow_name, run_id: run_id, generation: 0, cursor: cursor}
  end

  @doc """
  Gives the stop metadata of a span.

  ## Examples

      iex> DomovoyCore.Workflow.Server.Telemetry.stop_meta("issue_to_pr", "dom-43", :ready, 0, "review")
      %{workflow: "issue_to_pr", run_id: "dom-43", outcome: :ready, generation: 0, cursor: "review"}
  """
  @spec stop_meta(
          workflow_name :: String.t(),
          run_id :: String.t(),
          outcome :: atom(),
          generation :: non_neg_integer() | nil,
          cursor :: String.t() | nil
        ) :: meta()
  def stop_meta(workflow_name, run_id, outcome, generation, cursor)
      when is_binary(workflow_name) and is_binary(run_id) do
    %{
      workflow: workflow_name,
      run_id: run_id,
      outcome: outcome,
      generation: generation,
      cursor: cursor
    }
  end

  @doc """
  Gives the start metadata of a resume, before the replay.

  The generation and the cursor are `nil` here, because the journal has not
  been read yet. The stop metadata fills them.

  ## Examples

      iex> DomovoyCore.Workflow.Server.Telemetry.resume_start_meta("issue_to_pr", "dom-43")
      %{workflow: "issue_to_pr", run_id: "dom-43", generation: nil, cursor: nil}
  """
  @spec resume_start_meta(workflow_name :: String.t(), run_id :: String.t()) :: meta()
  def resume_start_meta(workflow_name, run_id)
      when is_binary(workflow_name) and is_binary(run_id) do
    %{workflow: workflow_name, run_id: run_id, generation: nil, cursor: nil}
  end

  @doc """
  Gives the start metadata of one drive step.

  ## Examples

      iex> DomovoyCore.Workflow.Server.Telemetry.drive_start_meta("issue_to_pr", "dom-43", 0, "prepare", :stage)
      %{
        workflow: "issue_to_pr",
        run_id: "dom-43",
        generation: 0,
        cursor: "prepare",
        vertex: "prepare",
        kind: :stage
      }
  """
  @spec drive_start_meta(
          workflow_name :: String.t(),
          run_id :: String.t(),
          generation :: non_neg_integer(),
          cursor :: String.t() | nil,
          kind :: atom()
        ) :: meta()
  def drive_start_meta(workflow_name, run_id, generation, cursor, kind)
      when is_binary(workflow_name) and is_binary(run_id) do
    %{
      workflow: workflow_name,
      run_id: run_id,
      generation: generation,
      cursor: cursor,
      vertex: cursor,
      kind: kind
    }
  end

  @doc """
  Gives the stop metadata of one drive step.

  `kind` and `vertex` come from the cursor before the step.

  ## Examples

      iex> DomovoyCore.Workflow.Server.Telemetry.drive_stop_meta("issue_to_pr", "dom-43", :awaiting_decision, 0, "prepare", :stage)
      %{
        workflow: "issue_to_pr",
        run_id: "dom-43",
        outcome: :awaiting_decision,
        generation: 0,
        cursor: "prepare",
        vertex: "prepare",
        kind: :stage
      }
  """
  @spec drive_stop_meta(
          workflow_name :: String.t(),
          run_id :: String.t(),
          outcome :: atom(),
          generation :: non_neg_integer() | nil,
          cursor :: String.t() | nil,
          kind :: atom()
        ) :: meta()
  def drive_stop_meta(workflow_name, run_id, outcome, generation, cursor, kind)
      when is_binary(workflow_name) and is_binary(run_id) do
    %{
      workflow: workflow_name,
      run_id: run_id,
      outcome: outcome,
      generation: generation,
      cursor: cursor,
      vertex: cursor,
      kind: kind
    }
  end
end
