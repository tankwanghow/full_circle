defmodule FullCircle.Repo.Migrations.CreateBankPayments do
  use Ecto.Migration

  def change do
    alter table(:contacts) do
      add :bank_code, :string
      add :bank_account_no, :string
      add :bank_account_name, :string
      add :bank_details_changed_at, :utc_datetime
    end

    create table(:bank_file_formats) do
      add :company_id, references(:companies, on_delete: :delete_all), null: false
      add :code, :string, null: false
      add :name, :string, null: false
      add :effective_from, :date, null: false
      add :spec, :map, null: false
      timestamps(type: :utc_datetime)
    end

    create unique_index(:bank_file_formats, [:company_id, :code, :effective_from],
             name: :bank_file_formats_unique_code_effective
           )

    create table(:bank_payment_profiles) do
      add :company_id, references(:companies, on_delete: :delete_all), null: false
      add :account_id, references(:accounts, on_delete: :delete_all), null: false
      add :format_code, :string, null: false
      add :our_account_no, :string, null: false
      add :start_date, :date, null: false
      add :params, :map, null: false, default: %{}
      timestamps(type: :utc_datetime)
    end

    create unique_index(:bank_payment_profiles, [:company_id, :account_id])

    # CASCADE keeps company deletion working; there is no other delete path
    # for formats, profiles or payments.
    create table(:bank_payment_batches) do
      add :company_id, references(:companies, on_delete: :delete_all), null: false
      add :profile_id, references(:bank_payment_profiles, on_delete: :delete_all), null: false
      add :format_id, references(:bank_file_formats, on_delete: :delete_all), null: false
      add :spec, :map, null: false
      add :payment_date, :date, null: false
      add :filename_stem, :string, null: false
      add :filename, :string, null: false
      add :seq, :integer, null: false
      add :header, :map, null: false
      add :count, :integer, null: false
      add :total, :decimal, null: false
      add :status, :string, null: false, default: "exported"
      add :submitted_by_id, references(:users, on_delete: :nilify_all)
      add :submitted_at, :utc_datetime
      add :result_imported_at, :utc_datetime
      add :result_filename, :string
      add :void_reason, :string
      add :voided_by_id, references(:users, on_delete: :nilify_all)
      add :voided_at, :utc_datetime
      add :created_by_id, references(:users, on_delete: :nilify_all)
      timestamps(type: :utc_datetime)
    end

    create unique_index(:bank_payment_batches, [:company_id, :filename])
    create index(:bank_payment_batches, [:company_id, :filename_stem])

    # Banks require a record id that is never reused.
    execute "CREATE SEQUENCE bank_payment_record_seq", "DROP SEQUENCE bank_payment_record_seq"

    create table(:bank_payment_batch_lines) do
      add :batch_id, references(:bank_payment_batches, on_delete: :delete_all), null: false
      add :payment_id, references(:payments, on_delete: :delete_all), null: false
      add :record_no, :bigint, null: false
      add :status, :string, null: false, default: "pending"
      add :live, :boolean, null: false, default: true
      add :bank_reason, :string
      add :released_by_id, references(:users, on_delete: :nilify_all)
      add :released_at, :utc_datetime
      add :payment_no, :string, null: false
      add :doc_date, :date, null: false
      add :amount, :decimal, null: false
      add :bank_code, :string, null: false
      add :bank_account_no, :string, null: false
      add :bank_account_name, :string, null: false
      add :contact_name, :string, null: false
      add :email, :string
      add :reg_no, :string
      add :descriptions, :string
      add :advice, {:array, :map}, null: false, default: []
    end

    # A Payment is in at most one live line, so it is never paid twice by file.
    create unique_index(:bank_payment_batch_lines, [:payment_id],
             where: "live",
             name: :bank_payment_batch_lines_one_live_per_payment
           )

    create unique_index(:bank_payment_batch_lines, [:record_no])
    create index(:bank_payment_batch_lines, [:batch_id])

    create table(:bank_payment_dismissals) do
      add :company_id, references(:companies, on_delete: :delete_all), null: false
      add :payment_id, references(:payments, on_delete: :delete_all), null: false
      add :user_id, references(:users, on_delete: :nilify_all)
      add :note, :string
      timestamps(type: :utc_datetime, updated_at: false)
    end

    create unique_index(:bank_payment_dismissals, [:payment_id])

    create table(:bank_payment_downloads) do
      add :batch_id, references(:bank_payment_batches, on_delete: :delete_all), null: false
      add :user_id, references(:users, on_delete: :nilify_all)
      add :reason, :string
      timestamps(type: :utc_datetime, updated_at: false)
    end

    create index(:bank_payment_downloads, [:batch_id])
  end
end
