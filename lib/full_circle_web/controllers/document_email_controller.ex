defmodule FullCircleWeb.DocumentEmailController do
  use FullCircleWeb, :controller

  alias FullCircle.{Repo, Sys, DocumentNotifier}
  alias FullCircleWeb.SharedDocument

  # doc_type => {schema module, display name, customer association}.
  # Invoice/Receipt/Credit/Debit Notes associate the customer as `:contact`;
  # Delivery and Order associate it as `:customer`.
  @doc_types %{
    "Invoice" => {FullCircle.Billing.Invoice, "Invoice", :contact},
    "Receipt" => {FullCircle.ReceiveFund.Receipt, "Receipt", :contact},
    "CreditNote" => {FullCircle.DebCre.CreditNote, "Credit Note", :contact},
    "DebitNote" => {FullCircle.DebCre.DebitNote, "Debit Note", :contact},
    "Delivery" => {FullCircle.Product.Delivery, "Delivery Order", :customer},
    "Order" => {FullCircle.Product.Order, "Order", :customer}
  }

  # GET /email_document/new — returns the document customer's email to pre-fill
  # the recipient prompt. Best-effort: returns "" if anything is unavailable.
  def new(conn, %{"company_id" => company_id, "doc_type" => doc_type, "doc_id" => doc_id}) do
    recipient =
      case load_document(conn.assigns.current_user, company_id, doc_type, doc_id) do
        {:ok, doc, _name, assoc} -> contact_email(doc, assoc)
        {:error, _} -> ""
      end

    json(conn, %{recipient: recipient})
  end

  def new(conn, _params), do: json(conn, %{recipient: ""})

  # POST /email_document — signs a token, builds the public link, sends the email.
  def create(conn, %{
        "company_id" => company_id,
        "doc_type" => doc_type,
        "doc_id" => doc_id,
        "email" => email
      }) do
    user = conn.assigns.current_user

    with true <- is_binary(email) and String.trim(email) != "",
         {:ok, _doc, name, _assoc} <- load_document(user, company_id, doc_type, doc_id),
         company <- Sys.get_company!(company_id),
         token <- SharedDocument.sign(doc_type, doc_id, company_id, user.id),
         url <- shared_document_url(doc_type, doc_id, token),
         {:ok, _email} <-
           DocumentNotifier.deliver_document_link(
             String.trim(email),
             "Your #{name} from #{company.name}",
             url,
             company
           ) do
      json(conn, %{ok: true})
    else
      false -> json(conn, %{ok: false, error: "A recipient email is required."})
      {:error, reason} -> json(conn, %{ok: false, error: error_message(reason)})
      _ -> json(conn, %{ok: false, error: "Could not send the email."})
    end
  end

  def create(conn, _params),
    do: json(conn, %{ok: false, error: "Missing required fields."})

  # Verifies the user belongs to the company and the document exists in it.
  # Returns {:ok, doc, display_name, customer_assoc} or {:error, reason}.
  defp load_document(user, company_id, doc_type, doc_id) do
    case @doc_types[doc_type] do
      nil ->
        {:error, :unknown_doc_type}

      {schema, name, assoc} ->
        cond do
          is_nil(user) ->
            {:error, :not_found}

          is_nil(Sys.get_company_user(company_id, user.id)) ->
            {:error, :not_found}

          true ->
            case fetch_document(schema, doc_id, company_id) do
              nil -> {:error, :not_found}
              doc -> {:ok, doc, name, assoc}
            end
        end
    end
  end

  defp fetch_document(schema, doc_id, company_id) do
    Repo.get_by(schema, id: doc_id, company_id: company_id)
  rescue
    Ecto.Query.CastError -> nil
  end

  defp contact_email(doc, assoc) do
    contact = doc |> Repo.preload(assoc) |> Map.get(assoc)
    (contact && contact.email) || ""
  rescue
    _ -> ""
  end

  defp shared_document_url(doc_type, doc_id, token) do
    query = URI.encode_query(%{"pre_print" => "false", "token" => token})
    "#{FullCircleWeb.Endpoint.url()}/shared/#{doc_type}/#{doc_id}/print?#{query}"
  end

  defp error_message(:unknown_doc_type), do: "Unknown document type."
  defp error_message(:not_found), do: "Document not found or access denied."
  defp error_message(other), do: "Could not send the email (#{inspect(other)})."
end
