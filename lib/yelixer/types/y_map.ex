defmodule Yelixer.Types.YMap do
  @moduledoc """
  Collaborative map type built on the YATA CRDT.

  Map entries use parent_sub to store the key. Each key has at most one
  non-deleted item — setting a key creates a new item and marks the old
  one as deleted (last-write-wins).
  """

  alias Yelixer.{Doc, ID, Item, BlockStore, StateVector, Integrate}

  @doc "Set a key to a value."
  def set(%Doc{} = doc, type_name, key, value) do
    # Mark any existing item for this key as deleted
    doc = delete_existing(doc, type_name, key)

    clock = StateVector.get(BlockStore.state_vector(doc.store), doc.client_id)
    id = ID.new(doc.client_id, clock)
    item = Item.new(id, nil, nil, {:any, [value]}, {:named, type_name}, key)
    store = BlockStore.push(doc.store, item)
    %{doc | store: store}
  end

  @doc "Get the value for a key, or nil if not found."
  def get(%Doc{} = doc, type_name, key) do
    case find_current_item(doc.store, type_name, key) do
      nil -> nil
      %Item{content: {:any, [value]}} -> value
    end
  end

  @doc "Delete a key."
  def delete(%Doc{} = doc, type_name, key) do
    delete_existing(doc, type_name, key)
  end

  @doc "Check if a key exists."
  def has_key?(%Doc{} = doc, type_name, key) do
    find_current_item(doc.store, type_name, key) != nil
  end

  @doc "Get all entries as a map."
  def to_map(%Doc{} = doc, type_name) do
    doc.store.clients
    |> Enum.flat_map(fn {_client, items} -> items end)
    |> Enum.filter(fn %Item{parent: parent, parent_sub: sub, deleted: deleted} ->
      parent == {:named, type_name} and sub != nil and not deleted
    end)
    |> Enum.reduce(%{}, fn %Item{parent_sub: key, content: {:any, [value]}}, acc ->
      # Last one wins (by clock order)
      Map.put(acc, key, value)
    end)
  end

  defp find_current_item(store, type_name, key) do
    store.clients
    |> Enum.flat_map(fn {_client, items} -> items end)
    |> Enum.filter(fn %Item{parent: parent, parent_sub: sub, deleted: deleted} ->
      parent == {:named, type_name} and sub == key and not deleted
    end)
    |> List.last()
  end

  defp delete_existing(doc, type_name, key) do
    case find_current_item(doc.store, type_name, key) do
      nil ->
        doc

      %Item{id: id} ->
        store = Integrate.mark_deleted(doc.store, id)
        %{doc | store: store}
    end
  end
end
