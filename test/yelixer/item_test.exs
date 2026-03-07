defmodule Yelixer.ItemTest do
  use ExUnit.Case, async: true

  alias Yelixer.{ID, Item}

  test "creates an item with string content" do
    item = Item.new(ID.new(1, 0), nil, nil, {:string, "hello"}, {:named, "text"}, nil)
    assert item.id == ID.new(1, 0)
    assert item.content == {:string, "hello"}
    assert item.length == 5
    assert item.deleted == false
  end

  test "string content length is character count" do
    item = Item.new(ID.new(1, 0), nil, nil, {:string, "abc"}, {:named, "text"}, nil)
    assert item.length == 3
  end

  test "deleted content has its stored length" do
    item = Item.new(ID.new(1, 0), nil, nil, {:deleted, 4}, {:named, "text"}, nil)
    assert item.length == 4
    assert item.deleted == true
  end

  test "any content length is element count" do
    item = Item.new(ID.new(1, 0), nil, nil, {:any, [1, "two", 3.0]}, {:named, "arr"}, nil)
    assert item.length == 3
  end

  test "single-value content types have length 1" do
    for content <- [{:embed, %{"img" => "url"}}, {:format, {"bold", true}}, {:type, :array}] do
      item = Item.new(ID.new(1, 0), nil, nil, content, {:named, "x"}, nil)
      assert item.length == 1
    end
  end

  test "binary content length is byte size" do
    item = Item.new(ID.new(1, 0), nil, nil, {:binary, <<1, 2, 3, 4>>}, {:named, "x"}, nil)
    assert item.length == 4
  end

  test "preserves origin and right_origin" do
    item =
      Item.new(
        ID.new(1, 5),
        ID.new(1, 3),
        ID.new(2, 0),
        {:string, "x"},
        {:named, "text"},
        nil
      )

    assert item.origin == ID.new(1, 3)
    assert item.right_origin == ID.new(2, 0)
  end

  test "preserves parent_sub for map entries" do
    item = Item.new(ID.new(1, 0), nil, nil, {:any, [42]}, {:named, "map"}, "key")
    assert item.parent_sub == "key"
  end
end
