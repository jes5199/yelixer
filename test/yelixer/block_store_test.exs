defmodule Yelixer.BlockStoreTest do
  use ExUnit.Case, async: true

  alias Yelixer.{ID, Item, BlockStore, StateVector}

  defp make_item(client, clock, content \\ {:string, "a"}) do
    Item.new(ID.new(client, clock), nil, nil, content, {:named, "text"}, nil)
  end

  test "new block store is empty" do
    bs = BlockStore.new()
    assert BlockStore.get(bs, ID.new(1, 0)) == nil
  end

  test "push and retrieve an item" do
    bs = BlockStore.new() |> BlockStore.push(make_item(1, 0))
    item = BlockStore.get(bs, ID.new(1, 0))
    assert item.id == ID.new(1, 0)
  end

  test "retrieve item by clock within its range" do
    bs = BlockStore.new() |> BlockStore.push(make_item(1, 0, {:string, "hello"}))
    item = BlockStore.get(bs, ID.new(1, 3))
    assert item.id == ID.new(1, 0)
    assert item.length == 5
  end

  test "returns nil for clock beyond stored range" do
    bs = BlockStore.new() |> BlockStore.push(make_item(1, 0))
    assert BlockStore.get(bs, ID.new(1, 1)) == nil
    assert BlockStore.get(bs, ID.new(2, 0)) == nil
  end

  test "state_vector reflects highest clock + length per client" do
    bs =
      BlockStore.new()
      |> BlockStore.push(make_item(1, 0, {:string, "ab"}))
      |> BlockStore.push(make_item(1, 2, {:string, "c"}))
      |> BlockStore.push(make_item(2, 0))

    sv = BlockStore.state_vector(bs)
    assert StateVector.get(sv, 1) == 3
    assert StateVector.get(sv, 2) == 1
  end

  test "multiple items per client maintain order" do
    bs =
      BlockStore.new()
      |> BlockStore.push(make_item(1, 0, {:string, "a"}))
      |> BlockStore.push(make_item(1, 1, {:string, "b"}))
      |> BlockStore.push(make_item(1, 2, {:string, "c"}))

    assert BlockStore.get(bs, ID.new(1, 0)).content == {:string, "a"}
    assert BlockStore.get(bs, ID.new(1, 1)).content == {:string, "b"}
    assert BlockStore.get(bs, ID.new(1, 2)).content == {:string, "c"}
  end

  test "client_blocks returns blocks for a specific client" do
    bs =
      BlockStore.new()
      |> BlockStore.push(make_item(1, 0))
      |> BlockStore.push(make_item(2, 0))

    assert length(BlockStore.client_blocks(bs, 1)) == 1
    assert length(BlockStore.client_blocks(bs, 2)) == 1
    assert BlockStore.client_blocks(bs, 3) == []
  end
end
