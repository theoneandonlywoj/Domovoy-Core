defmodule DomovoyCore.DoctestTest do
  use ExUnit.Case, async: true

  doctest DomovoyCore
  doctest DomovoyCore.Arrow
  doctest DomovoyCore.Binding
  doctest DomovoyCore.Choice
  doctest DomovoyCore.Context
  doctest DomovoyCore.Decider
  doctest DomovoyCore.Decider.Person
  doctest DomovoyCore.Decision
  doctest DomovoyCore.Engine
  doctest DomovoyCore.Engine.Order
  doctest DomovoyCore.Engine.Resolve
  doctest DomovoyCore.Engine.Scheduler
  doctest DomovoyCore.Error
  doctest DomovoyCore.Event
  doctest DomovoyCore.Graph
  doctest DomovoyCore.Job
  doctest DomovoyCore.Journal
  doctest DomovoyCore.Journal.FileSystem
  doctest DomovoyCore.Name
  doctest DomovoyCore.Node
  doctest DomovoyCore.Record
  doctest DomovoyCore.Retry
  doctest DomovoyCore.Run
  doctest DomovoyCore.Runner
  doctest DomovoyCore.Stage
  doctest DomovoyCore.Store
  doctest DomovoyCore.Store.FileSystem
  doctest DomovoyCore.Type
  doctest DomovoyCore.Type.Any
  doctest DomovoyCore.Type.Boolean
  doctest DomovoyCore.Type.Choice
  doctest DomovoyCore.Type.Directory
  doctest DomovoyCore.Type.Integer
  doctest DomovoyCore.Type.Map
  doctest DomovoyCore.Type.String
  doctest DomovoyCore.Validator
  doctest DomovoyCore.Value
  doctest DomovoyCore.Vertex
  doctest DomovoyCore.Workflow
  doctest DomovoyCore.Workflow.Server
  doctest DomovoyCore.Workflow.Server.Telemetry
end
