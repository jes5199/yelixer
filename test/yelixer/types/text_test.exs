defmodule Yelixer.Types.TextTest do
  use ExUnit.Case, async: true

  alias Yelixer.{Doc, Types.Text}

  defp new_doc(client_id) do
    doc = Doc.new(client_id: client_id)
    {doc, _} = Doc.get_or_create_type(doc, "text", :text)
    doc
  end

  test "insert and read text" do
    doc = new_doc(1)
    doc = Text.insert(doc, "text", 0, "hello")
    assert Text.to_string(doc, "text") == "hello"
  end

  test "insert at end" do
    doc = new_doc(1)
    doc = Text.insert(doc, "text", 0, "hello")
    doc = Text.insert(doc, "text", 5, " world")
    assert Text.to_string(doc, "text") == "hello world"
  end

  test "insert at beginning" do
    doc = new_doc(1)
    doc = Text.insert(doc, "text", 0, "world")
    doc = Text.insert(doc, "text", 0, "hello ")
    assert Text.to_string(doc, "text") == "hello world"
  end

  test "insert in middle" do
    doc = new_doc(1)
    doc = Text.insert(doc, "text", 0, "hllo")
    doc = Text.insert(doc, "text", 1, "e")
    assert Text.to_string(doc, "text") == "hello"
  end

  test "delete text range" do
    doc = new_doc(1)
    doc = Text.insert(doc, "text", 0, "hello world")
    doc = Text.delete(doc, "text", 5, 6)
    assert Text.to_string(doc, "text") == "hello"
  end

  test "delete from beginning" do
    doc = new_doc(1)
    doc = Text.insert(doc, "text", 0, "hello")
    doc = Text.delete(doc, "text", 0, 2)
    assert Text.to_string(doc, "text") == "llo"
  end

  test "length" do
    doc = new_doc(1)
    doc = Text.insert(doc, "text", 0, "hello")
    assert Text.length(doc, "text") == 5
  end

  test "length after delete" do
    doc = new_doc(1)
    doc = Text.insert(doc, "text", 0, "hello")
    doc = Text.delete(doc, "text", 0, 2)
    assert Text.length(doc, "text") == 3
  end

  test "multiple inserts build up text" do
    doc = new_doc(1)
    doc = Text.insert(doc, "text", 0, "a")
    doc = Text.insert(doc, "text", 1, "b")
    doc = Text.insert(doc, "text", 2, "c")
    assert Text.to_string(doc, "text") == "abc"
  end

  test "empty text" do
    doc = new_doc(1)
    assert Text.to_string(doc, "text") == ""
    assert Text.length(doc, "text") == 0
  end
end
