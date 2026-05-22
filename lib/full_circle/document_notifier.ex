defmodule FullCircle.DocumentNotifier do
  @moduledoc "Builds and delivers the customer-facing 'view your document' email."

  import Swoosh.Email

  alias FullCircle.Mailer

  @doc """
  Emails `recipient` a link to view a document. `company` is a map/struct with
  `:name` and `:email`. Returns `{:ok, email}` or `{:error, reason}`.
  """
  def deliver_document_link(recipient, subject, url, company) do
    from_addr =
      Application.get_env(:full_circle, :mail_from, {"FullCircle", "tankwanghow@gmail.com"})

    email =
      new()
      |> to(recipient)
      |> from(from_addr)
      |> reply_to(company.email || elem(from_addr, 1))
      |> subject(subject)
      |> text_body("""

      Hello,

      #{company.name} has shared a E-Invoice document with you. You can view and print it
      using the link below:

      #{url}

      This link will work for 30 days.

      Thank you,
      #{company.name}
      """)

    with {:ok, _metadata} <- Mailer.deliver(email) do
      {:ok, email}
    end
  end
end
