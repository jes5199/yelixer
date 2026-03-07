defmodule Yelixer.Encoding do
  @moduledoc """
  Binary encoding/decoding for Yjs V1 wire protocol.
  Uses unsigned LEB128 varint encoding.
  """

  alias Yelixer.{StateVector, DeleteSet, ID, Item, BlockStore, Doc, Integrate}

  # Content type refs (matching Yjs V1 format)
  @content_ref_deleted 1
  @content_ref_json 2
  @content_ref_binary 3
  @content_ref_string 4
  @content_ref_embed 5
  @content_ref_format 6
  @content_ref_type 7
  @content_ref_any 8

  # Info byte bit flags (Yjs convention)
  @has_origin 128
  @has_right_origin 64
  @has_parent_sub 32

  # --- Varint (unsigned LEB128) ---

  def encode_uint(n) when n < 128, do: <<n>>

  def encode_uint(n) do
    <<1::1, Bitwise.band(n, 0x7F)::7, encode_uint(Bitwise.bsr(n, 7))::binary>>
  end

  def decode_uint(binary), do: decode_uint(binary, 0, 0)

  defp decode_uint(<<0::1, value::7, rest::binary>>, acc, shift) do
    {acc + Bitwise.bsl(value, shift), rest}
  end

  defp decode_uint(<<1::1, value::7, rest::binary>>, acc, shift) do
    decode_uint(rest, acc + Bitwise.bsl(value, shift), shift + 7)
  end

  # --- String ---

  def encode_string(s) do
    bytes = :erlang.iolist_to_binary(s)
    <<encode_uint(byte_size(bytes))::binary, bytes::binary>>
  end

  def decode_string(binary) do
    {len, rest} = decode_uint(binary)
    <<s::binary-size(len), rest2::binary>> = rest
    {s, rest2}
  end

  # --- State Vector ---

  def encode_state_vector(%StateVector{clocks: clocks}) do
    count = map_size(clocks)

    pairs =
      Enum.reduce(clocks, <<>>, fn {client, clock}, acc ->
        <<acc::binary, encode_uint(client)::binary, encode_uint(clock)::binary>>
      end)

    <<encode_uint(count)::binary, pairs::binary>>
  end

  def decode_state_vector(binary) do
    {count, rest} = decode_uint(binary)
    decode_sv_pairs(rest, count, StateVector.new())
  end

  defp decode_sv_pairs(rest, 0, sv), do: {sv, rest}

  defp decode_sv_pairs(binary, remaining, sv) do
    {client, rest} = decode_uint(binary)
    {clock, rest} = decode_uint(rest)
    decode_sv_pairs(rest, remaining - 1, StateVector.set(sv, client, clock))
  end

  # --- Delete Set ---
  # Format: varint num_clients, then per client:
  #   varint client_id, varint num_ranges, then per range:
  #     varint clock, varint length

  def encode_delete_set(%DeleteSet{clients: clients}) do
    count = map_size(clients)

    body =
      Enum.reduce(clients, <<>>, fn {client, ranges}, acc ->
        num_ranges = length(ranges)

        ranges_bin =
          Enum.reduce(ranges, <<>>, fn {start, stop}, racc ->
            <<racc::binary, encode_uint(start)::binary, encode_uint(stop - start)::binary>>
          end)

        <<acc::binary, encode_uint(client)::binary, encode_uint(num_ranges)::binary,
          ranges_bin::binary>>
      end)

    <<encode_uint(count)::binary, body::binary>>
  end

  def decode_delete_set(binary) do
    {count, rest} = decode_uint(binary)
    decode_ds_clients(rest, count, DeleteSet.new())
  end

  defp decode_ds_clients(rest, 0, ds), do: {ds, rest}

  defp decode_ds_clients(binary, remaining, ds) do
    {client, rest} = decode_uint(binary)
    {num_ranges, rest} = decode_uint(rest)
    {ds, rest} = decode_ds_ranges(rest, num_ranges, ds, client)
    decode_ds_clients(rest, remaining - 1, ds)
  end

  defp decode_ds_ranges(rest, 0, ds, _client), do: {ds, rest}

  defp decode_ds_ranges(binary, remaining, ds, client) do
    {clock, rest} = decode_uint(binary)
    {len, rest} = decode_uint(rest)
    ds = DeleteSet.insert(ds, client, clock, len)
    decode_ds_ranges(rest, remaining - 1, ds, client)
  end

  # --- Update Encoding ---
  # Format:
  #   varint num_clients
  #   for each client (sorted by client id descending):
  #     varint num_structs
  #     varint client_id
  #     varint first_clock
  #     for each struct:
  #       byte info (bits 0-4: content ref, bit 5: has_parent_sub, bit 6: has_right_origin, bit 7: has_origin)
  #       [origin ID if has_origin]
  #       [right_origin ID if has_right_origin]
  #       [parent info if neither origin nor right_origin]
  #       [parent_sub string if has_parent_sub]
  #       content data
  #   delete_set

  def encode_update(%Doc{store: store, delete_set: ds}) do
    clients = store.clients

    # Sort clients by ID descending (Yjs convention)
    sorted_clients =
      clients
      |> Enum.sort_by(fn {client, _} -> client end, :desc)

    num_clients = length(sorted_clients)

    structs_bin =
      Enum.reduce(sorted_clients, <<>>, fn {client, items}, acc ->
        if items == [] do
          acc
        else
          first_clock = hd(items).id.clock
          num_items = length(items)

          items_bin =
            Enum.reduce(items, <<>>, fn item, iacc ->
              <<iacc::binary, encode_item(item)::binary>>
            end)

          <<acc::binary, encode_uint(num_items)::binary, encode_uint(client)::binary,
            encode_uint(first_clock)::binary, items_bin::binary>>
        end
      end)

    ds_bin = encode_delete_set(ds)

    <<encode_uint(num_clients)::binary, structs_bin::binary, ds_bin::binary>>
  end

  defp encode_item(%Item{} = item) do
    content_ref = content_type_ref(item.content)

    info =
      content_ref
      |> Bitwise.bor(if item.origin != nil, do: @has_origin, else: 0)
      |> Bitwise.bor(if item.right_origin != nil, do: @has_right_origin, else: 0)
      |> Bitwise.bor(if item.parent_sub != nil, do: @has_parent_sub, else: 0)

    bin = <<info>>

    # Write origin
    bin =
      if item.origin != nil do
        <<bin::binary, encode_id(item.origin)::binary>>
      else
        bin
      end

    # Write right_origin
    bin =
      if item.right_origin != nil do
        <<bin::binary, encode_id(item.right_origin)::binary>>
      else
        bin
      end

    # Write parent if no origin and no right_origin
    bin =
      if item.origin == nil and item.right_origin == nil do
        case item.parent do
          {:named, name} ->
            # parent info = true (named)
            <<bin::binary, encode_uint(1)::binary, encode_string(name)::binary>>

          {:id, id} ->
            # parent info = false (id)
            <<bin::binary, encode_uint(0)::binary, encode_id(id)::binary>>
        end
      else
        bin
      end

    # Write parent_sub
    bin =
      if item.parent_sub != nil do
        <<bin::binary, encode_string(item.parent_sub)::binary>>
      else
        bin
      end

    # Write content
    <<bin::binary, encode_content(item.content)::binary>>
  end

  defp encode_id(%ID{client: client, clock: clock}) do
    <<encode_uint(client)::binary, encode_uint(clock)::binary>>
  end

  defp decode_id(binary) do
    {client, rest} = decode_uint(binary)
    {clock, rest} = decode_uint(rest)
    {ID.new(client, clock), rest}
  end

  defp content_type_ref({:deleted, _}), do: @content_ref_deleted
  defp content_type_ref({:json, _}), do: @content_ref_json
  defp content_type_ref({:binary, _}), do: @content_ref_binary
  defp content_type_ref({:string, _}), do: @content_ref_string
  defp content_type_ref({:embed, _}), do: @content_ref_embed
  defp content_type_ref({:format, _}), do: @content_ref_format
  defp content_type_ref({:type, _}), do: @content_ref_type
  defp content_type_ref({:any, _}), do: @content_ref_any

  defp encode_content({:string, s}), do: encode_string(s)
  defp encode_content({:deleted, n}), do: encode_uint(n)
  defp encode_content({:any, values}), do: encode_any_list(values)
  defp encode_content({:binary, b}), do: <<encode_uint(byte_size(b))::binary, b::binary>>
  defp encode_content({:embed, value}), do: encode_string(Jason.encode!(value))

  defp encode_content({:format, {key, value}}) do
    <<encode_string(key)::binary, encode_string(Jason.encode!(value))::binary>>
  end

  defp encode_content({:type, type_ref}), do: encode_uint(type_ref_to_int(type_ref))
  defp encode_content({:json, values}), do: encode_json_list(values)

  # Encode a list of Any values using Yjs any encoding
  defp encode_any_list(values) do
    len = length(values)
    body = Enum.reduce(values, <<>>, fn v, acc -> <<acc::binary, encode_any(v)::binary>> end)
    <<encode_uint(len)::binary, body::binary>>
  end

  # Yjs Any encoding: type byte + value
  # 119 = undefined, 120 = null, 121 = integer, 122 = float32,
  # 123 = float64, 124 = bigint, 125 = false, 126 = true, 127 = string
  # 116 = object, 117 = array
  defp encode_any(nil), do: <<120>>
  defp encode_any(true), do: <<126>>
  defp encode_any(false), do: <<125>>

  defp encode_any(n) when is_integer(n) do
    <<123, n::float-64>>
  end

  defp encode_any(f) when is_float(f) do
    <<123, f::float-64>>
  end

  defp encode_any(s) when is_binary(s) do
    <<119, encode_string(s)::binary>>
  end

  defp encode_any(list) when is_list(list) do
    <<117, encode_uint(length(list))::binary,
      (Enum.reduce(list, <<>>, fn v, acc -> <<acc::binary, encode_any(v)::binary>> end)
       |> :erlang.iolist_to_binary())::binary>>
  end

  defp encode_any(map) when is_map(map) do
    <<116, encode_uint(map_size(map))::binary,
      (Enum.reduce(map, <<>>, fn {k, v}, acc ->
         <<acc::binary, encode_string(to_string(k))::binary, encode_any(v)::binary>>
       end)
       |> :erlang.iolist_to_binary())::binary>>
  end

  defp decode_any(<<120, rest::binary>>), do: {nil, rest}
  defp decode_any(<<126, rest::binary>>), do: {true, rest}
  defp decode_any(<<125, rest::binary>>), do: {false, rest}
  defp decode_any(<<123, f::float-64, rest::binary>>), do: {round_if_integer(f), rest}

  defp decode_any(<<119, rest::binary>>) do
    decode_string(rest)
  end

  defp decode_any(<<117, rest::binary>>) do
    {len, rest} = decode_uint(rest)
    decode_any_list(rest, len, [])
  end

  defp decode_any(<<116, rest::binary>>) do
    {len, rest} = decode_uint(rest)
    decode_any_map(rest, len, %{})
  end

  defp decode_any_list(rest, 0, acc), do: {Enum.reverse(acc), rest}

  defp decode_any_list(rest, n, acc) do
    {val, rest} = decode_any(rest)
    decode_any_list(rest, n - 1, [val | acc])
  end

  defp decode_any_map(rest, 0, acc), do: {acc, rest}

  defp decode_any_map(rest, n, acc) do
    {key, rest} = decode_string(rest)
    {val, rest} = decode_any(rest)
    decode_any_map(rest, n - 1, Map.put(acc, key, val))
  end

  defp round_if_integer(f) do
    rounded = round(f)
    if rounded == f, do: rounded, else: f
  end

  defp encode_json_list(values) do
    len = length(values)
    body = Enum.reduce(values, <<>>, fn v, acc -> <<acc::binary, encode_string(v)::binary>> end)
    <<encode_uint(len)::binary, body::binary>>
  end

  defp type_ref_to_int(:array), do: 0
  defp type_ref_to_int(:map), do: 1
  defp type_ref_to_int(:text), do: 2
  defp type_ref_to_int(:xml_element), do: 3
  defp type_ref_to_int(:xml_fragment), do: 4
  defp type_ref_to_int(:xml_hook), do: 5
  defp type_ref_to_int(:xml_text), do: 6
  defp type_ref_to_int(_), do: 0

  defp int_to_type_ref(0), do: :array
  defp int_to_type_ref(1), do: :map
  defp int_to_type_ref(2), do: :text
  defp int_to_type_ref(3), do: :xml_element
  defp int_to_type_ref(4), do: :xml_fragment
  defp int_to_type_ref(5), do: :xml_hook
  defp int_to_type_ref(6), do: :xml_text
  defp int_to_type_ref(_), do: :unknown

  # --- Update Decoding ---

  def apply_update(%Doc{} = doc, binary) do
    {items, ds, _rest} = decode_update(binary)

    # Filter out items we already have
    sv = BlockStore.state_vector(doc.store)

    {doc, sv, pending} = integrate_items(items, doc, sv, [])

    # Retry pending items whose dependencies are now available
    {doc, _sv} = retry_pending(doc, sv, pending)

    # Apply delete set
    doc =
      Enum.reduce(Map.to_list(ds.clients), doc, fn {client, ranges}, doc ->
        Enum.reduce(ranges, doc, fn {start, stop}, doc ->
          Enum.reduce(start..(stop - 1)//1, doc, fn clock, doc ->
            store = Integrate.mark_deleted(doc.store, ID.new(client, clock))
            %{doc | store: store}
          end)
        end)
      end)

    {:ok, doc}
  end

  defp integrate_items([], doc, sv, pending), do: {doc, sv, Enum.reverse(pending)}

  defp integrate_items([item | rest], doc, sv, pending) do
    client_clock = StateVector.get(sv, item.id.client)

    if item.id.clock < client_clock do
      # Already have this item, skip
      integrate_items(rest, doc, sv, pending)
    else
      case try_integrate_item(item, doc, sv) do
        {:ok, doc, sv} ->
          integrate_items(rest, doc, sv, pending)

        :pending ->
          integrate_items(rest, doc, sv, [item | pending])
      end
    end
  end

  defp try_integrate_item(item, doc, sv) do
    item = resolve_parent(item, doc.store)
    type_name = parent_type_name(item)

    case type_name do
      nil ->
        # Can't resolve parent yet — defer for retry
        :pending

      name ->
        {doc, _} = Doc.get_or_create_type(doc, name, :unknown)
        {:ok, store} = Integrate.integrate(doc.store, item, name)
        sv = StateVector.advance(sv, item.id.client, item.id.clock + item.length)
        {:ok, %{doc | store: store}, sv}
    end
  end

  defp retry_pending(doc, sv, []), do: {doc, sv}

  defp retry_pending(doc, sv, pending) do
    {doc, sv, still_pending} = integrate_items(pending, doc, sv, [])

    if length(still_pending) < length(pending) do
      # Made progress, retry remaining
      retry_pending(doc, sv, still_pending)
    else
      # No progress — push remaining items to store without sequence integration
      {doc, sv} =
        Enum.reduce(still_pending, {doc, sv}, fn item, {doc, sv} ->
          store = BlockStore.push(doc.store, item)
          sv = StateVector.advance(sv, item.id.client, item.id.clock + item.length)
          {%{doc | store: store}, sv}
        end)

      {doc, sv}
    end
  end

  defp parent_type_name(%Item{parent: {:named, name}}), do: name
  defp parent_type_name(_), do: nil

  defp resolve_parent(%Item{parent: {:infer, ref_id}} = item, store) when not is_nil(ref_id) do
    case BlockStore.get(store, ref_id) do
      nil -> item
      ref_item -> %{item | parent: ref_item.parent}
    end
  end

  defp resolve_parent(item, _store), do: item

  def decode_update(binary) do
    {num_clients, rest} = decode_uint(binary)
    {items, rest} = decode_clients(rest, num_clients, [])
    {ds, rest} = decode_delete_set(rest)
    {items, ds, rest}
  end

  defp decode_clients(rest, 0, acc), do: {acc, rest}

  defp decode_clients(binary, remaining, acc) do
    {num_structs, rest} = decode_uint(binary)
    {client, rest} = decode_uint(rest)
    {first_clock, rest} = decode_uint(rest)
    {items, rest} = decode_structs(rest, num_structs, client, first_clock, [])
    decode_clients(rest, remaining - 1, acc ++ items)
  end

  defp decode_structs(rest, 0, _client, _clock, acc), do: {Enum.reverse(acc), rest}

  defp decode_structs(binary, remaining, client, clock, acc) do
    {item, rest, next_clock} = decode_struct(binary, client, clock)
    decode_structs(rest, remaining - 1, client, next_clock, [item | acc])
  end

  defp decode_struct(<<info, rest::binary>>, client, clock) do
    content_ref = Bitwise.band(info, 0x1F)
    has_origin = Bitwise.band(info, @has_origin) != 0
    has_right_origin = Bitwise.band(info, @has_right_origin) != 0
    has_parent_sub = Bitwise.band(info, @has_parent_sub) != 0

    # Read origin
    {origin, rest} =
      if has_origin do
        decode_id(rest)
      else
        {nil, rest}
      end

    # Read right_origin
    {right_origin, rest} =
      if has_right_origin do
        decode_id(rest)
      else
        {nil, rest}
      end

    # Read parent (only if both origin and right_origin are nil)
    {parent, rest} =
      if origin == nil and right_origin == nil do
        {parent_info, rest} = decode_uint(rest)

        if parent_info == 1 do
          # Named parent
          {name, rest} = decode_string(rest)
          {{:named, name}, rest}
        else
          # ID parent
          {id, rest} = decode_id(rest)
          {{:id, id}, rest}
        end
      else
        # Parent will be inferred from origin/right_origin during integration
        {{:infer, origin || right_origin}, rest}
      end

    # Read parent_sub
    {parent_sub, rest} =
      if has_parent_sub do
        decode_string(rest)
      else
        {nil, rest}
      end

    # Read content
    {content, rest} = decode_content(rest, content_ref)

    item = Item.new(ID.new(client, clock), origin, right_origin, content, parent, parent_sub)
    next_clock = clock + item.length

    {item, rest, next_clock}
  end

  defp decode_content(rest, @content_ref_string) do
    {s, rest} = decode_string(rest)
    {{:string, s}, rest}
  end

  defp decode_content(rest, @content_ref_deleted) do
    {n, rest} = decode_uint(rest)
    {{:deleted, n}, rest}
  end

  defp decode_content(rest, @content_ref_any) do
    {len, rest} = decode_uint(rest)
    {values, rest} = decode_any_list(rest, len, [])
    {{:any, values}, rest}
  end

  defp decode_content(rest, @content_ref_binary) do
    {len, rest} = decode_uint(rest)
    <<b::binary-size(len), rest2::binary>> = rest
    {{:binary, b}, rest2}
  end

  defp decode_content(rest, @content_ref_type) do
    {ref_int, rest} = decode_uint(rest)
    {{:type, int_to_type_ref(ref_int)}, rest}
  end

  defp decode_content(rest, @content_ref_json) do
    {len, rest} = decode_uint(rest)
    {values, rest} = decode_json_list(rest, len, [])
    {{:json, values}, rest}
  end

  defp decode_content(rest, @content_ref_embed) do
    {s, rest} = decode_string(rest)
    {{:embed, Jason.decode!(s)}, rest}
  end

  defp decode_content(rest, @content_ref_format) do
    {key, rest} = decode_string(rest)
    {value_str, rest} = decode_string(rest)
    {{:format, {key, Jason.decode!(value_str)}}, rest}
  end

  defp decode_json_list(rest, 0, acc), do: {Enum.reverse(acc), rest}

  defp decode_json_list(rest, n, acc) do
    {s, rest} = decode_string(rest)
    decode_json_list(rest, n - 1, [s | acc])
  end
end
