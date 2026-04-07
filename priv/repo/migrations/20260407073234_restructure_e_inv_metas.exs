defmodule FullCircle.Repo.Migrations.RestructureEInvMetas do
  use Ecto.Migration

  def up do
    alter table(:e_inv_metas) do
      add :environment, :string, default: "production"
      add :sandbox, :map, default: %{}
      add :production, :map, default: %{}
      add :paths, :map, default: %{}
    end

    flush()

    execute """
    UPDATE e_inv_metas SET
      environment = 'production',
      production = jsonb_build_object(
        'api_base', COALESCE(e_inv_apibaseurl, ''),
        'id_base', COALESCE(e_inv_idsrvbaseurl, ''),
        'client_id', COALESCE(e_inv_clientid, ''),
        'client_secret1', COALESCE(e_inv_clientsecret1, ''),
        'client_secret2', COALESCE(e_inv_clientsecret2, ''),
        'expiration', COALESCE(e_inv_clientsecretexpiration::text, '')
      ),
      sandbox = '{}',
      paths = jsonb_build_object(
        'login', COALESCE(login_url, ''),
        'search', COALESCE(search_url, ''),
        'get_doc', COALESCE(get_doc_url, ''),
        'get_doc_details', COALESCE(get_doc_details_url, ''),
        'submit', '/api/v1.0/documentsubmissions/',
        'portal', 'https://myinvois.hasil.gov.my',
        'sandbox_portal', 'https://preprod.myinvois.hasil.gov.my'
      )
    """

    alter table(:e_inv_metas) do
      remove :e_inv_apibaseurl
      remove :e_inv_idsrvbaseurl
      remove :e_inv_clientid
      remove :e_inv_clientsecret1
      remove :e_inv_clientsecret2
      remove :e_inv_clientsecretexpiration
      remove :login_url
      remove :search_url
      remove :get_doc_url
      remove :get_doc_details_url
    end
  end

  def down do
    alter table(:e_inv_metas) do
      add :e_inv_apibaseurl, :string
      add :e_inv_idsrvbaseurl, :string
      add :e_inv_clientid, :string
      add :e_inv_clientsecret1, :string
      add :e_inv_clientsecret2, :string
      add :e_inv_clientsecretexpiration, :date
      add :login_url, :string
      add :search_url, :string
      add :get_doc_url, :string
      add :get_doc_details_url, :string
    end

    flush()

    execute """
    UPDATE e_inv_metas SET
      e_inv_apibaseurl = production->>'api_base',
      e_inv_idsrvbaseurl = production->>'id_base',
      e_inv_clientid = production->>'client_id',
      e_inv_clientsecret1 = production->>'client_secret1',
      e_inv_clientsecret2 = production->>'client_secret2',
      e_inv_clientsecretexpiration = NULLIF(production->>'expiration', '')::date,
      login_url = paths->>'login',
      search_url = paths->>'search',
      get_doc_url = paths->>'get_doc',
      get_doc_details_url = paths->>'get_doc_details'
    """

    alter table(:e_inv_metas) do
      remove :environment
      remove :sandbox
      remove :production
      remove :paths
    end
  end
end
