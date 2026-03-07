defmodule Yelixer.Integrate do
  @moduledoc """
  YATA integration algorithm — resolves where new items go in the sequence.

  The algorithm uses origin (left neighbor at creation time) and right_origin
  (right neighbor at creation time) to find the correct insertion position.
  When conflicts exist (multiple items with the same origin), client IDs
  break ties deterministically.
  """

  alias Yelixer.{ID, Item, BlockStore}

  @doc """
  Integrate an item into the block store at the correct position
  determined by the YATA algorithm.
  """
  def integrate(%BlockStore{} = store, %Item{} = item, type_name) do
    index = find_insertion_index(store, item, type_name)
    store = BlockStore.insert_at(store, type_name, index, item)
    {:ok, store}
  end

  @doc """
  Get the content values of the sequence for a type, excluding deleted items.
  """
  def sequence(%BlockStore{} = store, type_name) do
    store
    |> BlockStore.get_sequence(type_name)
    |> Enum.flat_map(&content_values/1)
  end

  @doc """
  Mark an item as deleted in the block store.
  """
  def mark_deleted(%BlockStore{} = store, %ID{} = id) do
    case BlockStore.get(store, id) do
      nil ->
        store

      item ->
        deleted_item = %{item | deleted: true}

        clients =
          Map.update!(store.clients, id.client, fn blocks ->
            Enum.map(blocks, fn
              %Item{id: ^id} -> deleted_item
              other -> other
            end)
          end)

        %{store | clients: clients}
    end
  end

  # Find where to insert an item in the sequence using YATA conflict resolution.
  defp find_insertion_index(store, item, type_name) do
    seq_ids = Map.get(store.sequences, type_name, [])

    # Find position after origin
    start_index =
      case item.origin do
        nil ->
          0

        origin_id ->
          case find_id_index(seq_ids, store, origin_id) do
            nil -> 0
            idx -> idx + 1
          end
      end

    # Find position before right_origin
    end_index =
      case item.right_origin do
        nil ->
          length(seq_ids)

        ro_id ->
          case find_id_index(seq_ids, store, ro_id) do
            nil -> length(seq_ids)
            idx -> idx
          end
      end

    if start_index >= end_index do
      start_index
    else
      resolve_conflicts(store, item, seq_ids, start_index, end_index)
    end
  end

  # YATA conflict resolution loop.
  # Scans items between start_index and end_index to find the correct position.
  defp resolve_conflicts(_store, _item, _seq_ids, index, end_index) when index >= end_index do
    index
  end

  defp resolve_conflicts(store, item, seq_ids, index, end_index) do
    other_id = Enum.at(seq_ids, index)
    other = BlockStore.get(store, other_id)

    cond do
      other == nil ->
        index

      # Case 1: Same origin — compare client IDs
      # In YATA: lower client ID goes first (to the left)
      other.origin == item.origin ->
        cond do
          # We have lower client ID — insert before other
          item.id.client < other.id.client ->
            index

          # Same client ID or higher, but same right_origin — we're already positioned
          item.id.client > other.id.client ->
            # Other has lower client ID, skip past it
            resolve_conflicts(store, item, seq_ids, index + 1, end_index)

          # Same client ID (shouldn't happen in practice) and same right_origin
          item.right_origin == other.right_origin ->
            index

          true ->
            resolve_conflicts(store, item, seq_ids, index + 1, end_index)
        end

      # Case 2: Different origin — check if other's origin is before us
      true ->
        case other.origin do
          nil ->
            # Other has no origin, it breaks out
            index

          other_origin ->
            other_origin_idx = find_id_index(seq_ids, store, other_origin)

            if other_origin_idx != nil and other_origin_idx < index do
              # Other's origin is in items_before_origin but not in conflicting_items
              # Move past it
              resolve_conflicts(store, item, seq_ids, index + 1, end_index)
            else
              index
            end
        end
    end
  end

  # Find the index in the sequence where an ID lives.
  # Handles multi-character items by checking clock ranges.
  defp find_id_index(seq_ids, store, %ID{} = target_id) do
    Enum.find_index(seq_ids, fn seq_id ->
      item = BlockStore.get(store, seq_id)

      item != nil and
        item.id.client == target_id.client and
        target_id.clock >= item.id.clock and
        target_id.clock < item.id.clock + item.length
    end)
  end

  defp content_values(%Item{content: {:string, s}}), do: [s]
  defp content_values(%Item{content: {:any, list}}), do: list
  defp content_values(%Item{content: {:deleted, _}}), do: []
  defp content_values(%Item{content: content}), do: [content]
end
