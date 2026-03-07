defmodule Yelixer.Doc do
  alias Yelixer.{BlockStore, DeleteSet}

  @type t :: %__MODULE__{
          client_id: non_neg_integer(),
          store: BlockStore.t(),
          delete_set: DeleteSet.t(),
          types: %{String.t() => atom()}
        }

  defstruct [:client_id, :store, :delete_set, :types]

  def new(opts \\ []) do
    client_id = Keyword.get(opts, :client_id, :rand.uniform(1_000_000_000))

    %__MODULE__{
      client_id: client_id,
      store: BlockStore.new(),
      delete_set: DeleteSet.new(),
      types: %{}
    }
  end

  def has_type?(%__MODULE__{types: types}, name), do: Map.has_key?(types, name)

  def get_or_create_type(%__MODULE__{types: types} = doc, name, type_ref) do
    if Map.has_key?(types, name) do
      {doc, Map.get(types, name)}
    else
      doc = %{doc | types: Map.put(types, name, type_ref)}
      {doc, type_ref}
    end
  end
end
