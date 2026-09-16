defmodule DomovoyCoreTest do
  use ExUnit.Case
  doctest DomovoyCore

  test "greets the world" do
    assert DomovoyCore.hello() == :world
  end
end
