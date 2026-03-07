defmodule Yelixer.Item do
  alias Yelixer.ID

  @type content ::
          {:string, String.t()}
          | {:any, list()}
          | {:binary, binary()}
          | {:deleted, non_neg_integer()}
          | {:embed, term()}
          | {:format, {String.t(), term()}}
          | {:type, atom()}
          | {:json, list()}
          | {:doc, term()}

  @type parent_ref :: {:named, String.t()} | {:id, ID.t()}

  @type t :: %__MODULE__{
          id: ID.t(),
          origin: ID.t() | nil,
          right_origin: ID.t() | nil,
          content: content(),
          parent: parent_ref(),
          parent_sub: String.t() | nil,
          deleted: boolean(),
          length: non_neg_integer()
        }

  defstruct [:id, :origin, :right_origin, :content, :parent, :parent_sub, :deleted, :length]

  def new(id, origin, right_origin, content, parent, parent_sub) do
    %__MODULE__{
      id: id,
      origin: origin,
      right_origin: right_origin,
      content: content,
      parent: parent,
      parent_sub: parent_sub,
      deleted: match?({:deleted, _}, content),
      length: content_length(content)
    }
  end

  defp content_length({:string, s}), do: String.length(s)
  defp content_length({:any, list}), do: length(list)
  defp content_length({:binary, b}), do: byte_size(b)
  defp content_length({:deleted, n}), do: n
  defp content_length({:json, list}), do: length(list)
  defp content_length(_), do: 1
end
