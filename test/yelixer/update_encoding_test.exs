defmodule Yelixer.UpdateEncodingTest do
  use ExUnit.Case, async: true

  alias Yelixer.{Doc, Types.Text, Types.Array, Types.YMap, Encoding, StateVector, BlockStore}

  test "encode and decode update roundtrip — text" do
    doc1 = Doc.new(client_id: 1)
    {doc1, _} = Doc.get_or_create_type(doc1, "text", :text)
    doc1 = Text.insert(doc1, "text", 0, "hello")

    update = Encoding.encode_update(doc1)
    assert is_binary(update)

    doc2 = Doc.new(client_id: 2)
    {doc2, _} = Doc.get_or_create_type(doc2, "text", :text)
    {:ok, doc2} = Encoding.apply_update(doc2, update)

    assert Text.to_string(doc2, "text") == "hello"
  end

  test "encode and decode update roundtrip — array" do
    doc1 = Doc.new(client_id: 1)
    {doc1, _} = Doc.get_or_create_type(doc1, "arr", :array)
    doc1 = Array.insert(doc1, "arr", 0, [1, 2, 3])

    update = Encoding.encode_update(doc1)

    doc2 = Doc.new(client_id: 2)
    {doc2, _} = Doc.get_or_create_type(doc2, "arr", :array)
    {:ok, doc2} = Encoding.apply_update(doc2, update)

    assert Array.to_list(doc2, "arr") == [1, 2, 3]
  end

  test "sync two text docs" do
    doc1 = Doc.new(client_id: 1)
    doc2 = Doc.new(client_id: 2)
    {doc1, _} = Doc.get_or_create_type(doc1, "text", :text)
    {doc2, _} = Doc.get_or_create_type(doc2, "text", :text)

    doc1 = Text.insert(doc1, "text", 0, "hello ")
    doc2 = Text.insert(doc2, "text", 0, "world")

    update1 = Encoding.encode_update(doc1)
    update2 = Encoding.encode_update(doc2)

    {:ok, doc1} = Encoding.apply_update(doc1, update2)
    {:ok, doc2} = Encoding.apply_update(doc2, update1)

    text1 = Text.to_string(doc1, "text")
    text2 = Text.to_string(doc2, "text")
    assert text1 == text2
  end

  test "state vector encodes correctly from doc" do
    doc = Doc.new(client_id: 1)
    {doc, _} = Doc.get_or_create_type(doc, "text", :text)
    doc = Text.insert(doc, "text", 0, "hi")

    sv = BlockStore.state_vector(doc.store)
    assert StateVector.get(sv, 1) == 2
  end

  test "applying same update twice is idempotent" do
    doc1 = Doc.new(client_id: 1)
    {doc1, _} = Doc.get_or_create_type(doc1, "text", :text)
    doc1 = Text.insert(doc1, "text", 0, "abc")

    update = Encoding.encode_update(doc1)

    doc2 = Doc.new(client_id: 2)
    {doc2, _} = Doc.get_or_create_type(doc2, "text", :text)

    {:ok, doc2} = Encoding.apply_update(doc2, update)
    text_once = Text.to_string(doc2, "text")

    {:ok, doc2} = Encoding.apply_update(doc2, update)
    text_twice = Text.to_string(doc2, "text")

    assert text_once == text_twice
  end
end
