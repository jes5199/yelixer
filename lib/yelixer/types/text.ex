defmodule Yelixer.Types.Text do
  @moduledoc """
  Collaborative text type built on the YATA CRDT.

  Each insert creates an Item with {:string, content} that gets integrated
  into the document's sequence for the named type.
  """

  alias Yelixer.{Doc, ID, Item, BlockStore, Integrate, StateVector}

  @doc "Insert text at a character position."
  def insert(%Doc{} = doc, type_name, index, text) when is_binary(text) and byte_size(text) > 0 do
    # Insert each character as a separate item for correct mid-item insertion.
    # Each subsequent char uses the previous one as its origin.
    text
    |> String.graphemes()
    |> Enum.with_index()
    |> Enum.reduce(doc, fn {char, i}, doc ->
      {origin, right_origin} = find_origins(doc.store, type_name, index + i)
      clock = StateVector.get(BlockStore.state_vector(doc.store), doc.client_id)
      id = ID.new(doc.client_id, clock)
      item = Item.new(id, origin, right_origin, {:string, char}, {:named, type_name}, nil)
      {:ok, store} = Integrate.integrate(doc.store, item, type_name)
      %{doc | store: store}
    end)
  end

  @doc "Delete `len` characters starting at `index`."
  def delete(%Doc{} = doc, type_name, index, len) when len > 0 do
    items_to_delete = find_items_in_range(doc.store, type_name, index, len)

    store =
      Enum.reduce(items_to_delete, doc.store, fn id, store ->
        Integrate.mark_deleted(store, id)
      end)

    %{doc | store: store}
  end

  @doc "Get the text content as a string."
  def to_string(%Doc{} = doc, type_name) do
    doc.store
    |> BlockStore.get_sequence(type_name)
    |> Enum.map(fn %Item{content: {:string, s}} -> s end)
    |> Enum.join()
  end

  @doc "Get the character length of the text."
  def length(%Doc{} = doc, type_name) do
    doc.store
    |> BlockStore.get_sequence(type_name)
    |> Enum.reduce(0, fn %Item{length: len}, acc -> acc + len end)
  end

  # Find the origin (left neighbor) and right_origin (right neighbor)
  # for an insertion at a given character index.
  defp find_origins(store, type_name, index) do
    seq = BlockStore.get_sequence(store, type_name)

    if index == 0 and seq == [] do
      {nil, nil}
    else
      {left_item, right_item} = find_neighbors(seq, index)

      origin =
        case left_item do
          nil -> nil
          %Item{id: id, length: len} -> ID.new(id.client, id.clock + len - 1)
        end

      right_origin =
        case right_item do
          nil -> nil
          %Item{id: id} -> id
        end

      {origin, right_origin}
    end
  end

  # Walk through items to find the left and right neighbors at a character index.
  defp find_neighbors(items, index) do
    find_neighbors(items, index, 0, nil)
  end

  defp find_neighbors([], _index, _pos, left), do: {left, nil}

  defp find_neighbors([item | rest], index, pos, left) do
    item_end = pos + item.length

    cond do
      index <= pos ->
        {left, item}

      index >= item_end ->
        find_neighbors(rest, index, item_end, item)

      true ->
        # Index falls within this item — need to split conceptually
        # The origin is within this item at the given offset
        # For simplicity, we treat the whole item as origin
        # TODO: Item splitting for mid-item insertions
        {item, List.first(rest)}
    end
  end

  # Find item IDs that cover a character range for deletion.
  defp find_items_in_range(store, type_name, index, len) do
    seq = BlockStore.get_sequence(store, type_name)
    collect_ids_in_range(seq, index, len, 0, [])
  end

  defp collect_ids_in_range(_, _, 0, _, acc), do: Enum.reverse(acc)
  defp collect_ids_in_range([], _, _, _, acc), do: Enum.reverse(acc)

  defp collect_ids_in_range([item | rest], index, remaining, pos, acc) do
    item_end = pos + item.length

    cond do
      item_end <= index ->
        collect_ids_in_range(rest, index, remaining, item_end, acc)

      pos >= index ->
        # Entire item is in range
        to_take = min(item.length, remaining)
        collect_ids_in_range(rest, index, remaining - to_take, item_end, [item.id | acc])

      true ->
        # Partial overlap — for now, delete the whole item
        # TODO: Item splitting
        to_take = min(item_end - index, remaining)
        collect_ids_in_range(rest, index, remaining - to_take, item_end, [item.id | acc])
    end
  end
end
