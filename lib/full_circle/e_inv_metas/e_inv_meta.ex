defmodule FullCircle.EInvMetas.EInvMeta do
  use FullCircle.Schema
  import Ecto.Changeset

  schema "e_inv_metas" do
    field :e_inv_apibaseurl, :string
    field :e_inv_idsrvbaseurl, :string
    field :e_inv_clientid, :string
    field :e_inv_clientsecret1, :string
    field :e_inv_clientsecret2, :string
    field :e_inv_clientsecretexpiration, :date
    field :token, :string
    field :login_url, :string
    field :search_url, :string
    field :get_doc_url, :string
    field :get_doc_details_url, :string

    belongs_to(:company, FullCircle.Sys.Company, type: :binary_id)

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(e_inv_meta, attrs) do
    e_inv_meta
    |> cast(attrs, [
      :e_inv_apibaseurl,
      :e_inv_idsrvbaseurl,
      :e_inv_clientid,
      :e_inv_clientsecret1,
      :e_inv_clientsecret2,
      :e_inv_clientsecretexpiration,
      :token,
      :login_url,
      :search_url,
      :get_doc_url,
      :get_doc_details_url,
      :company_id
    ])
    |> validate_required([
      :e_inv_apibaseurl,
      :e_inv_idsrvbaseurl,
      :e_inv_clientid,
      :e_inv_clientsecret1,
      :e_inv_clientsecret2,
      :e_inv_clientsecretexpiration,
      :login_url,
      :search_url,
      :get_doc_url,
      :get_doc_details_url,
      :company_id
    ])
  end
end
