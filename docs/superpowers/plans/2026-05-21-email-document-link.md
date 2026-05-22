# Email Document Link — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an Email button to the print layout so staff can email a customer a secure, 30-day link to view/print a sales document.

**Architecture:** A new public (no-login) `live_session` exposes `/shared/<Type>/:id/print` routes that reuse the *existing* `*.Print` LiveViews unchanged. A `Phoenix.Token`-based `on_mount` hook authenticates those requests from a signed token and assigns `current_user`/`current_company` from it. A small JSON controller signs the token and sends the link by email via Swoosh.

**Tech Stack:** Elixir, Phoenix 1.8 / LiveView 1.1, `Phoenix.Token` (stateless signed tokens), Swoosh (mailer already configured).

**Planning refinement vs. spec:** To keep the 6 LiveView edits identical and centralise per-type knowledge in one place, `email_doc` carries only `{type, id, company_id}` (no email/doc_no). The recipient email is fetched by a `GET /email_document/new` endpoint when the button is clicked; all per-type schema knowledge lives in one `@doc_types` map in `DocumentEmailController`. The email subject is `"Your <DocType> from <Company>"` (no document number).

---

## File Structure

**New files**
- `lib/full_circle_web/shared_document.ex` — token `sign/4`, `verify/1`, and the `on_mount/4` auth hook for the public session.
- `lib/full_circle/document_notifier.ex` — builds and delivers the Swoosh email.
- `lib/full_circle_web/controllers/document_email_controller.ex` — `GET /email_document/new` (recipient lookup) and `POST /email_document` (send).
- `lib/full_circle_web/controllers/shared_document_controller.ex` — `GET /shared/expired` page.
- `lib/full_circle_web/controllers/shared_document_html.ex` + `lib/full_circle_web/controllers/shared_document_html/expired.html.heex` — the expired-page template.
- `test/full_circle_web/shared_document_test.exs`
- `test/full_circle/document_notifier_test.exs`
- `test/full_circle_web/controllers/document_email_controller_test.exs`
- `test/full_circle_web/live/shared_document_live_test.exs`

**Modified files**
- `lib/full_circle_web/router.ex` — public `live_session`, controller routes, expired route.
- `lib/full_circle_web/components/layouts/print_root.html.heex` — Email button + JS + CSRF meta tag.
- `lib/full_circle_web/live/invoice_live/print.ex`
- `lib/full_circle_web/live/receipt_live/print.ex`
- `lib/full_circle_web/live/credit_note_live/print.ex`
- `lib/full_circle_web/live/debit_note_live/print.ex`
- `lib/full_circle_web/live/delivery_live/print.ex`
- `lib/full_circle_web/live/order_live/print.ex`

**Document type registry (used in several tasks):**

| `doc_type` | Schema module | Print LiveView | Display name |
|------------|---------------|----------------|--------------|
| `"Invoice"` | `FullCircle.Billing.Invoice` | `InvoiceLive.Print` | Invoice |
| `"Receipt"` | `FullCircle.ReceiveFund.Receipt` | `ReceiptLive.Print` | Receipt |
| `"CreditNote"` | `FullCircle.DebCre.CreditNote` | `CreditNoteLive.Print` | Credit Note |
| `"DebitNote"` | `FullCircle.DebCre.DebitNote` | `DebitNoteLive.Print` | Debit Note |
| `"Delivery"` | `FullCircle.Product.Delivery` | `DeliveryLive.Print` | Delivery Order |
| `"Order"` | `FullCircle.Product.Order` | `OrderLive.Print` | Order |

---

## Task 1: Token sign/verify in `SharedDocument`

**Files:**
- Create: `lib/full_circle_web/shared_document.ex`
- Test: `test/full_circle_web/shared_document_test.exs`

- [ ] **Step 1: Write the failing test**

Create `test/full_circle_web/shared_document_test.exs`:

```elixir
defmodule FullCircleWeb.SharedDocumentTest do
  use FullCircle.DataCase, async: true

  alias FullCircleWeb.SharedDocument

  @payload %{t: "Invoice", d: "doc-123", c: "company-1", u: "user-1"}

  describe "sign/4 and verify/1" do
    test "a freshly signed token verifies back to the payload" do
      token = SharedDocument.sign("Invoice", "doc-123", "company-1", "user-1")
      assert {:ok, payload} = SharedDocument.verify(token)
      assert payload == @payload
    end

    test "a tampered token is rejected" do
      token = SharedDocument.sign("Invoice", "doc-123", "company-1", "user-1")
      assert {:error, :invalid} = SharedDocument.verify(token <> "x")
    end

    test "a token older than 30 days is rejected as expired" do
      old =
        Phoenix.Token.sign(FullCircleWeb.Endpoint, "shared document", @payload,
          signed_at: System.system_time(:second) - 2_592_001
        )

      assert {:error, :expired} = SharedDocument.verify(old)
    end

    test "garbage input is rejected" do
      assert {:error, _} = SharedDocument.verify("not-a-token")
    end
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `mix test test/full_circle_web/shared_document_test.exs`
Expected: FAIL — `module FullCircleWeb.SharedDocument is not available`.

- [ ] **Step 3: Write the minimal implementation**

Create `lib/full_circle_web/shared_document.ex`:

```elixir
defmodule FullCircleWeb.SharedDocument do
  @moduledoc """
  Signed, time-limited tokens for the public "view this document" links, plus
  the LiveView `on_mount` hook that authenticates the public print routes from
  such a token instead of a logged-in session.
  """

  @salt "shared document"
  # 30 days, in seconds.
  @max_age 2_592_000

  @doc "Signs a stateless token carrying the document type, id, company id and sending user id."
  def sign(doc_type, doc_id, company_id, user_id) do
    Phoenix.Token.sign(FullCircleWeb.Endpoint, @salt, %{
      t: doc_type,
      d: doc_id,
      c: company_id,
      u: user_id
    })
  end

  @doc "Verifies a token. Returns {:ok, payload} or {:error, :expired | :invalid | term()}."
  def verify(token) when is_binary(token) do
    Phoenix.Token.verify(FullCircleWeb.Endpoint, @salt, token, max_age: @max_age)
  end

  def verify(_), do: {:error, :invalid}
end
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `mix test test/full_circle_web/shared_document_test.exs`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add lib/full_circle_web/shared_document.ex test/full_circle_web/shared_document_test.exs
git commit -m "feat: add SharedDocument signed-token helpers"
```

---

## Task 2: The `on_mount` token auth hook

**Files:**
- Modify: `lib/full_circle_web/shared_document.ex`

This hook is exercised end-to-end by the LiveView test in Task 9; no isolated unit test here.

- [ ] **Step 1: Add the `on_mount/4` hook**

Add these functions inside `FullCircleWeb.SharedDocument` (after `verify/1`):

```elixir
  @doc """
  on_mount hook for the public document routes. Verifies `params["token"]`,
  confirms it matches the route's `doc_type` and the `:id` in the path, then
  assigns `current_user`, `current_company` and `shared_view?: true` so the
  existing print LiveViews render unchanged. Any failure redirects to
  `/shared/expired`.
  """
  def on_mount({:verify_token, doc_type}, params, _session, socket) do
    with token when is_binary(token) <- params["token"],
         {:ok, %{t: ^doc_type, d: doc_id, c: company_id, u: user_id}} <- verify(token),
         true <- doc_id == params["id"],
         company when not is_nil(company) <-
           FullCircle.Repo.get(FullCircle.Sys.Company, company_id),
         user when not is_nil(user) <-
           FullCircle.Repo.get(FullCircle.UserAccounts.User, user_id) do
      {:cont,
       socket
       |> Phoenix.Component.assign(:current_company, company)
       |> Phoenix.Component.assign(:current_user, user)
       |> Phoenix.Component.assign(:shared_view?, true)}
    else
      _ -> {:halt, Phoenix.LiveView.redirect(socket, to: "/shared/expired")}
    end
  end
```

- [ ] **Step 2: Compile to verify it builds**

Run: `mix compile`
Expected: compiles, no warnings about `SharedDocument`.

- [ ] **Step 3: Commit**

```bash
git add lib/full_circle_web/shared_document.ex
git commit -m "feat: add SharedDocument on_mount token auth hook"
```

---

## Task 3: `DocumentNotifier` email module

**Files:**
- Create: `lib/full_circle/document_notifier.ex`
- Test: `test/full_circle/document_notifier_test.exs`

- [ ] **Step 1: Write the failing test**

Create `test/full_circle/document_notifier_test.exs`:

```elixir
defmodule FullCircle.DocumentNotifierTest do
  use FullCircle.DataCase, async: true
  import Swoosh.TestAssertions

  alias FullCircle.DocumentNotifier

  test "deliver_document_link/4 sends an email containing the link" do
    company = %{name: "Acme Sdn Bhd", email: "acme@example.com"}
    url = "https://app.example.com/shared/Invoice/abc/print?token=xyz"

    assert {:ok, _} =
             DocumentNotifier.deliver_document_link(
               "customer@example.com",
               "Your Invoice from Acme Sdn Bhd",
               url,
               company
             )

    assert_email_sent(fn email ->
      assert {_, "customer@example.com"} = hd(email.to)
      assert email.subject == "Your Invoice from Acme Sdn Bhd"
      assert email.text_body =~ url
      assert email.text_body =~ "30 days"
    end)
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `mix test test/full_circle/document_notifier_test.exs`
Expected: FAIL — `module FullCircle.DocumentNotifier is not available`.

- [ ] **Step 3: Write the minimal implementation**

Create `lib/full_circle/document_notifier.ex`:

```elixir
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

      #{company.name} has shared a document with you. You can view and print it
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
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `mix test test/full_circle/document_notifier_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/full_circle/document_notifier.ex test/full_circle/document_notifier_test.exs
git commit -m "feat: add DocumentNotifier for customer document emails"
```

---

## Task 4: `DocumentEmailController`

**Files:**
- Create: `lib/full_circle_web/controllers/document_email_controller.ex`
- Modify: `lib/full_circle_web/router.ex`
- Test: `test/full_circle_web/controllers/document_email_controller_test.exs`

This task adds the controller and its two routes together so the test can exercise it.

- [ ] **Step 1: Add the routes**

In `lib/full_circle_web/router.ex`, find the block (around line 84):

```elixir
  scope "/", FullCircleWeb do
    pipe_through([:browser, :require_authenticated_user])

    live_session :require_authenticated_user,
```

Immediately after the `post("/update_active_company", ...)` / `get("/delete_active_company", ...)` lines that close that `scope` block, and still inside it, add:

```elixir
    get("/email_document/new", DocumentEmailController, :new)
    post("/email_document", DocumentEmailController, :create)
```

(They must sit inside the `scope "/", FullCircleWeb do ... pipe_through([:browser, :require_authenticated_user])` block so they get CSRF protection and authentication, but outside the `live_session` block.)

- [ ] **Step 2: Write the failing test**

Create `test/full_circle_web/controllers/document_email_controller_test.exs`:

```elixir
defmodule FullCircleWeb.DocumentEmailControllerTest do
  use FullCircleWeb.ConnCase, async: true

  import FullCircle.BillingFixtures
  import FullCircle.SysFixtures
  import Swoosh.TestAssertions

  setup %{conn: conn} do
    user = FullCircle.UserAccountsFixtures.user_fixture()
    company = company_fixture(user, %{})
    invoice = invoice_fixture(company, user)
    %{conn: log_in_user(conn, user), user: user, company: company, invoice: invoice}
  end

  describe "POST /email_document" do
    test "sends the email and returns ok for an accessible document", %{
      conn: conn,
      company: company,
      invoice: invoice
    } do
      conn =
        post(conn, ~p"/email_document", %{
          "company_id" => company.id,
          "doc_type" => "Invoice",
          "doc_id" => invoice.id,
          "email" => "customer@example.com"
        })

      assert json_response(conn, 200) == %{"ok" => true}
      assert_email_sent(fn email -> assert {_, "customer@example.com"} = hd(email.to) end)
    end

    test "rejects an unknown doc_type", %{conn: conn, company: company, invoice: invoice} do
      conn =
        post(conn, ~p"/email_document", %{
          "company_id" => company.id,
          "doc_type" => "Nonsense",
          "doc_id" => invoice.id,
          "email" => "customer@example.com"
        })

      assert %{"ok" => false} = json_response(conn, 200)
    end

    test "rejects a document the user cannot access", %{conn: conn, company: company} do
      conn =
        post(conn, ~p"/email_document", %{
          "company_id" => company.id,
          "doc_type" => "Invoice",
          "doc_id" => Ecto.UUID.generate(),
          "email" => "customer@example.com"
        })

      assert %{"ok" => false} = json_response(conn, 200)
    end
  end

  describe "GET /email_document/new" do
    test "returns the document contact's email", %{
      conn: conn,
      company: company,
      invoice: invoice
    } do
      conn =
        get(conn, ~p"/email_document/new", %{
          "company_id" => company.id,
          "doc_type" => "Invoice",
          "doc_id" => invoice.id
        })

      assert %{"recipient" => _} = json_response(conn, 200)
    end
  end

  test "requires authentication", %{} do
    conn = build_conn()
    conn = post(conn, ~p"/email_document", %{})
    assert redirected_to(conn) =~ "/users/log_in"
  end
end
```

- [ ] **Step 3: Run the test to verify it fails**

Run: `mix test test/full_circle_web/controllers/document_email_controller_test.exs`
Expected: FAIL — `DocumentEmailController` does not exist / `UndefinedFunctionError`.

- [ ] **Step 4: Write the controller**

Create `lib/full_circle_web/controllers/document_email_controller.ex`:

```elixir
defmodule FullCircleWeb.DocumentEmailController do
  use FullCircleWeb, :controller

  alias FullCircle.StdInterface
  alias FullCircle.Sys
  alias FullCircle.{Repo, DocumentNotifier}
  alias FullCircleWeb.SharedDocument

  # doc_type => {schema module, display name}
  @doc_types %{
    "Invoice" => {FullCircle.Billing.Invoice, "Invoice"},
    "Receipt" => {FullCircle.ReceiveFund.Receipt, "Receipt"},
    "CreditNote" => {FullCircle.DebCre.CreditNote, "Credit Note"},
    "DebitNote" => {FullCircle.DebCre.DebitNote, "Debit Note"},
    "Delivery" => {FullCircle.Product.Delivery, "Delivery Order"},
    "Order" => {FullCircle.Product.Order, "Order"}
  }

  # GET /email_document/new — returns the document contact's email to pre-fill the prompt.
  def new(conn, %{"company_id" => company_id, "doc_type" => doc_type, "doc_id" => doc_id}) do
    case load_document(conn, company_id, doc_type, doc_id) do
      {:ok, doc, _name} ->
        contact = Repo.preload(doc, :contact).contact
        json(conn, %{recipient: (contact && contact.email) || ""})

      {:error, _} ->
        json(conn, %{recipient: ""})
    end
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
         {:ok, _doc, name} <- load_document(conn, company_id, doc_type, doc_id),
         company <- Sys.get_company!(company_id),
         token <- SharedDocument.sign(doc_type, doc_id, company_id, user.id),
         url <-
           url(~p"/shared/#{doc_type}/#{doc_id}/print?pre_print=false&token=#{token}"),
         {:ok, _email} <-
           DocumentNotifier.deliver_document_link(
             email,
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

  # Loads the document scoped to the current user + company. Returns
  # {:ok, doc, display_name} or {:error, reason}.
  defp load_document(conn, company_id, doc_type, doc_id) do
    user = conn.assigns.current_user

    case @doc_types[doc_type] do
      nil ->
        {:error, :unknown_doc_type}

      {schema, name} ->
        company = %Sys.Company{id: company_id}

        case StdInterface.get_one_by(schema, :id, doc_id, company, user) do
          nil -> {:error, :not_found}
          doc -> {:ok, doc, name}
        end
    end
  end

  defp error_message(:unknown_doc_type), do: "Unknown document type."
  defp error_message(:not_found), do: "Document not found or access denied."
  defp error_message(other), do: "Could not send the email (#{inspect(other)})."
end
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `mix test test/full_circle_web/controllers/document_email_controller_test.exs`
Expected: PASS (5 tests). The `~p"/shared/..."` verified route does not exist yet — if compilation fails on that line, continue to Task 5 first, then re-run; the route is added there. If you prefer strict ordering, temporarily build the URL with `url(~p"/")` replaced by a string and revisit — but the recommended order is: do Task 5 immediately after Step 4, then run this test.

- [ ] **Step 6: Commit**

```bash
git add lib/full_circle_web/controllers/document_email_controller.ex test/full_circle_web/controllers/document_email_controller_test.exs lib/full_circle_web/router.ex
git commit -m "feat: add DocumentEmailController for sending document links"
```

---

## Task 5: Public `live_session` + expired route

**Files:**
- Modify: `lib/full_circle_web/router.ex`

- [ ] **Step 1: Add the public live_session and expired route**

In `lib/full_circle_web/router.ex`, find the last `scope "/", FullCircleWeb do` block (the one around line 389 with `pipe_through([:browser])` and `live_session :current_user`). Add a new sibling `scope` block immediately before it (still after the `/companies/:company_id` scope):

```elixir
  # Public, no-login document links emailed to customers.
  scope "/", FullCircleWeb do
    pipe_through([:browser])

    get("/shared/expired", SharedDocumentController, :expired)

    live_session :public_shared_document,
      root_layout: {FullCircleWeb.Layouts, :print_root},
      on_mount: [{FullCircleWeb.Locale, :set_locale}] do
      live("/shared/Invoice/:id/print", InvoiceLive.Print, :print,
        on_mount: [{FullCircleWeb.SharedDocument, {:verify_token, "Invoice"}}]
      )

      live("/shared/Receipt/:id/print", ReceiptLive.Print, :print,
        on_mount: [{FullCircleWeb.SharedDocument, {:verify_token, "Receipt"}}]
      )

      live("/shared/CreditNote/:id/print", CreditNoteLive.Print, :print,
        on_mount: [{FullCircleWeb.SharedDocument, {:verify_token, "CreditNote"}}]
      )

      live("/shared/DebitNote/:id/print", DebitNoteLive.Print, :print,
        on_mount: [{FullCircleWeb.SharedDocument, {:verify_token, "DebitNote"}}]
      )

      live("/shared/Delivery/:id/print", DeliveryLive.Print, :print,
        on_mount: [{FullCircleWeb.SharedDocument, {:verify_token, "Delivery"}}]
      )

      live("/shared/Order/:id/print", OrderLive.Print, :print,
        on_mount: [{FullCircleWeb.SharedDocument, {:verify_token, "Order"}}]
      )
    end
  end
```

Note: `on_mount` may be given per-`live/4` route (the 4th-arg keyword list) — this lets each route bind its own `doc_type`. The session-level `on_mount` runs first, then the route-level one. If the installed LiveView version rejects per-route `on_mount`, fall back to six separate `live_session` blocks (one per type) each with the type-bound `on_mount`.

- [ ] **Step 2: Compile and check routes**

Run: `mix compile && mix phx.routes | grep shared`
Expected: compiles; the six `/shared/<Type>/:id/print` routes and `/shared/expired` are listed.

- [ ] **Step 3: Run the controller test from Task 4**

Run: `mix test test/full_circle_web/controllers/document_email_controller_test.exs`
Expected: PASS — the `~p"/shared/Invoice/..."` verified route now resolves.

- [ ] **Step 4: Commit**

```bash
git add lib/full_circle_web/router.ex
git commit -m "feat: add public shared-document routes"
```

---

## Task 6: `SharedDocumentController` expired page

**Files:**
- Create: `lib/full_circle_web/controllers/shared_document_controller.ex`
- Create: `lib/full_circle_web/controllers/shared_document_html.ex`
- Create: `lib/full_circle_web/controllers/shared_document_html/expired.html.heex`

- [ ] **Step 1: Create the controller**

Create `lib/full_circle_web/controllers/shared_document_controller.ex`:

```elixir
defmodule FullCircleWeb.SharedDocumentController do
  use FullCircleWeb, :controller

  def expired(conn, _params) do
    conn
    |> put_layout(false)
    |> render(:expired)
  end
end
```

- [ ] **Step 2: Create the HTML module**

Create `lib/full_circle_web/controllers/shared_document_html.ex`:

```elixir
defmodule FullCircleWeb.SharedDocumentHTML do
  use FullCircleWeb, :html

  embed_templates "shared_document_html/*"
end
```

- [ ] **Step 3: Create the template**

Create `lib/full_circle_web/controllers/shared_document_html/expired.html.heex`:

```heex
<!DOCTYPE html>
<html lang="en">
  <head>
    <meta charset="utf-8" />
    <title>{gettext("Link expired")}</title>
    <style>
      body { font-family: system-ui, Arial, sans-serif; background: #FAFAFA;
             display: flex; align-items: center; justify-content: center; height: 100vh; margin: 0; }
      .box { background: white; border: 1px solid #D3D3D3; border-radius: 8px;
             padding: 40px; max-width: 460px; text-align: center;
             box-shadow: 0 0 8px rgba(0,0,0,0.08); }
    </style>
  </head>
  <body>
    <div class="box">
      <h1>{gettext("This link is no longer valid")}</h1>
      <p>
        {gettext(
          "The document link has expired or is invalid. Please contact the company to request a new copy."
        )}
      </p>
    </div>
  </body>
</html>
```

- [ ] **Step 4: Compile and verify the page renders**

Run: `mix compile`
Expected: compiles cleanly.

Run: `mix test test/full_circle_web/shared_document_test.exs` (smoke check nothing broke).
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/full_circle_web/controllers/shared_document_controller.ex lib/full_circle_web/controllers/shared_document_html.ex lib/full_circle_web/controllers/shared_document_html/
git commit -m "feat: add expired shared-document link page"
```

---

## Task 7: Email button in `print_root.html.heex`

**Files:**
- Modify: `lib/full_circle_web/components/layouts/print_root.html.heex`

- [ ] **Step 1: Add the CSRF meta tag**

In `lib/full_circle_web/components/layouts/print_root.html.heex`, inside `<head>`, immediately after the `<title>...</title>` block, add:

```heex
    <meta name="csrf-token" content={Plug.CSRFProtection.get_csrf_token()} />
```

- [ ] **Step 2: Add the Email button**

Find the `#button` div:

```heex
    <div id="button">
      <a href="#" onclick="printElement('print-me')">{gettext("Print")}</a>
      <a href="#" onclick="closeTab()">{gettext("Close")}</a>
    </div>
```

Replace it with:

```heex
    <div id="button">
      <a href="#" onclick="printElement('print-me')">{gettext("Print")}</a>
      <a
        :if={assigns[:email_doc] && !assigns[:shared_view?]}
        id="email-btn"
        href="#"
        data-company-id={@email_doc.company_id}
        data-doc-type={@email_doc.type}
        data-doc-id={@email_doc.id}
        onclick="emailDocument(this); return false;"
      >{gettext("Email")}</a>
      <a href="#" onclick="closeTab()">{gettext("Close")}</a>
    </div>
```

- [ ] **Step 3: Add the JavaScript**

Inside the existing `<script>` block (after the `printElement` function definition, before `</script>`), add:

```javascript
      async function emailDocument(el) {
        const meta = document.querySelector("meta[name='csrf-token']");
        const csrf = meta ? meta.content : "";
        const companyId = el.dataset.companyId;
        const docType = el.dataset.docType;
        const docId = el.dataset.docId;

        let recipient = "";
        try {
          const q = `company_id=${encodeURIComponent(companyId)}` +
                    `&doc_type=${encodeURIComponent(docType)}` +
                    `&doc_id=${encodeURIComponent(docId)}`;
          const res = await fetch(`/email_document/new?${q}`, {
            headers: { "x-csrf-token": csrf }
          });
          const data = await res.json();
          recipient = data.recipient || "";
        } catch (e) { /* fall back to an empty prompt */ }

        const to = window.prompt("Email this document to:", recipient);
        if (!to || !to.trim()) { return; }

        try {
          const res = await fetch("/email_document", {
            method: "POST",
            headers: { "content-type": "application/json", "x-csrf-token": csrf },
            body: JSON.stringify({
              company_id: companyId, doc_type: docType, doc_id: docId, email: to.trim()
            })
          });
          const data = await res.json();
          if (data.ok) {
            alert("Document link emailed to " + to.trim() + ".");
          } else {
            alert("Could not send: " + (data.error || "unknown error"));
          }
        } catch (e) {
          alert("Could not send the email: " + e);
        }
      }
```

- [ ] **Step 4: Compile and verify**

Run: `mix compile`
Expected: compiles cleanly (template compiles as part of the web app).

- [ ] **Step 5: Commit**

```bash
git add lib/full_circle_web/components/layouts/print_root.html.heex
git commit -m "feat: add Email button to print layout"
```

---

## Task 8: `email_doc` assign in the 6 Print LiveViews

**Files (each modified identically in shape):**
- `lib/full_circle_web/live/invoice_live/print.ex`
- `lib/full_circle_web/live/receipt_live/print.ex`
- `lib/full_circle_web/live/credit_note_live/print.ex`
- `lib/full_circle_web/live/debit_note_live/print.ex`
- `lib/full_circle_web/live/delivery_live/print.ex`
- `lib/full_circle_web/live/order_live/print.ex`

In each file there are two `mount/3` clauses. **Only the first clause** — the one matching `%{"id" => id, "pre_print" => pre_print}` — gets one extra piped line. The second clause (`%{"ids" => ids, ...}`) is left untouched, so multi-print shows no button.

- [ ] **Step 1: Edit `invoice_live/print.ex`**

Change the first `mount/3` clause from:

```elixir
  def mount(%{"id" => id, "pre_print" => pre_print}, _session, socket) do
    ids = [id]

    {:ok,
     socket
     |> assign(page_title: gettext("Print"))
     |> assign(:pre_print, pre_print)
     |> set_page_defaults()
     |> fill_invoices(ids)}
  end
```

to:

```elixir
  def mount(%{"id" => id, "pre_print" => pre_print}, _session, socket) do
    ids = [id]

    {:ok,
     socket
     |> assign(page_title: gettext("Print"))
     |> assign(:pre_print, pre_print)
     |> set_page_defaults()
     |> fill_invoices(ids)
     |> assign(:email_doc, %{
       type: "Invoice",
       id: id,
       company_id: socket.assigns.current_company.id
     })}
  end
```

- [ ] **Step 2: Edit `receipt_live/print.ex`**

In the first `mount/3` clause, after `|> fill_receipts(ids)` add:

```elixir
     |> assign(:email_doc, %{
       type: "Receipt",
       id: id,
       company_id: socket.assigns.current_company.id
     })
```

- [ ] **Step 3: Edit `credit_note_live/print.ex`**

In the first `mount/3` clause, after `|> fill_credit_notes(ids)` add:

```elixir
     |> assign(:email_doc, %{
       type: "CreditNote",
       id: id,
       company_id: socket.assigns.current_company.id
     })
```

- [ ] **Step 4: Edit `debit_note_live/print.ex`**

In the first `mount/3` clause, after `|> fill_debit_notes(ids)` add:

```elixir
     |> assign(:email_doc, %{
       type: "DebitNote",
       id: id,
       company_id: socket.assigns.current_company.id
     })
```

- [ ] **Step 5: Edit `delivery_live/print.ex`**

In the first `mount/3` clause, after `|> fill_orders(ids)` add:

```elixir
     |> assign(:email_doc, %{
       type: "Delivery",
       id: id,
       company_id: socket.assigns.current_company.id
     })
```

- [ ] **Step 6: Edit `order_live/print.ex`**

In the first `mount/3` clause, after `|> fill_orders(ids)` add:

```elixir
     |> assign(:email_doc, %{
       type: "Order",
       id: id,
       company_id: socket.assigns.current_company.id
     })
```

- [ ] **Step 7: Compile**

Run: `mix compile --warnings-as-errors`
Expected: compiles cleanly, no unused-variable warnings (`id` is now used in every first clause).

- [ ] **Step 8: Commit**

```bash
git add lib/full_circle_web/live/invoice_live/print.ex lib/full_circle_web/live/receipt_live/print.ex lib/full_circle_web/live/credit_note_live/print.ex lib/full_circle_web/live/debit_note_live/print.ex lib/full_circle_web/live/delivery_live/print.ex lib/full_circle_web/live/order_live/print.ex
git commit -m "feat: expose email_doc assign on single-document print views"
```

---

## Task 9: Integration test for the public route

**Files:**
- Test: `test/full_circle_web/live/shared_document_live_test.exs`

- [ ] **Step 1: Write the test**

Create `test/full_circle_web/live/shared_document_live_test.exs`:

```elixir
defmodule FullCircleWeb.SharedDocumentLiveTest do
  use FullCircleWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import FullCircle.BillingFixtures
  import FullCircle.SysFixtures

  alias FullCircleWeb.SharedDocument

  setup do
    user = FullCircle.UserAccountsFixtures.user_fixture()
    company = company_fixture(user, %{})
    invoice = invoice_fixture(company, user)
    %{user: user, company: company, invoice: invoice}
  end

  test "a valid token renders the invoice print page without login", %{
    conn: conn,
    user: user,
    company: company,
    invoice: invoice
  } do
    token = SharedDocument.sign("Invoice", invoice.id, company.id, user.id)

    {:ok, _view, html} =
      live(conn, ~p"/shared/Invoice/#{invoice.id}/print?pre_print=false&token=#{token}")

    assert html =~ invoice.invoice_no
  end

  test "an invalid token redirects to the expired page", %{conn: conn, invoice: invoice} do
    assert {:error, {:redirect, %{to: "/shared/expired"}}} =
             live(conn, ~p"/shared/Invoice/#{invoice.id}/print?pre_print=false&token=bad")
  end

  test "a token for a different document is rejected", %{
    conn: conn,
    user: user,
    company: company,
    invoice: invoice
  } do
    token = SharedDocument.sign("Invoice", Ecto.UUID.generate(), company.id, user.id)

    assert {:error, {:redirect, %{to: "/shared/expired"}}} =
             live(conn, ~p"/shared/Invoice/#{invoice.id}/print?pre_print=false&token=#{token}")
  end
end
```

- [ ] **Step 2: Run the test**

Run: `mix test test/full_circle_web/live/shared_document_live_test.exs`
Expected: PASS (3 tests). If the first test fails on `invoice.invoice_no`, confirm the field name on the `Invoice` schema (`mix run -e "IO.inspect(FullCircle.Billing.Invoice.__schema__(:fields))"`) and adjust the assertion to a field that appears in the rendered print page.

- [ ] **Step 3: Commit**

```bash
git add test/full_circle_web/live/shared_document_live_test.exs
git commit -m "test: cover public shared-document route"
```

---

## Task 10: Full suite + manual smoke check

- [ ] **Step 1: Run the whole test suite**

Run: `mix test`
Expected: all tests pass (no regressions in the print LiveViews or elsewhere).

- [ ] **Step 2: Manual smoke check**

Run: `mix phx.server`, then in a browser:
1. Open a single invoice print page: `/companies/<company_id>/Invoice/<id>/print?pre_print=false`. Confirm an **Email** button appears between Print and Close.
2. Click Email → confirm the prompt is pre-filled with the contact's email → accept.
3. Confirm the dev mailbox at `/dev/mailbox` shows an email containing a `/shared/Invoice/.../print?...&token=...` link.
4. Open that link in a private window (logged out). Confirm the invoice renders and the Email button is **absent**.
5. Open `/shared/Invoice/<id>/print?pre_print=false&token=bad`. Confirm the expired page renders.
6. Open a `print_multi` page and confirm there is **no** Email button.

- [ ] **Step 3: Final commit (if any doc/cleanup changes)**

```bash
git add -A
git commit -m "chore: finish email-document-link feature"
```

---

## Self-Review

**Spec coverage:**
- Email button on `print_root` for the 6 sales doc types → Task 7 (button, gated on `email_doc`) + Task 8 (assign on the 6 single-doc mounts only). ✓
- Secure link, no PDF → Tasks 1, 5 (token + public route). ✓
- Confirm/edit recipient → Task 7 (`GET /email_document/new` pre-fill + `prompt()`). ✓
- 30-day expiry → Task 1 (`@max_age 2_592_000`). ✓
- Reuse existing Print LiveViews via token `on_mount` → Tasks 2, 5. ✓
- Single documents only → Task 8 (first `mount` clause only). ✓
- Expired/invalid page → Task 6. ✓
- Email via Swoosh `:mail_from` → Task 3. ✓
- Tests for token, controller, notifier, public route → Tasks 1, 3, 4, 9. ✓

**Placeholder scan:** No TBD/TODO. Task 4 Step 5 and Task 9 Step 2 contain conditional verification instructions (route ordering, schema field name) — these are concrete fallback steps, not placeholders.

**Type consistency:** `email_doc` shape `%{type, id, company_id}` is identical in Task 7 (reads `@email_doc.company_id/.type/.id`) and Task 8 (assigns those three keys). Token payload `%{t,d,c,u}` is consistent across `sign/4`, `verify/1`, `on_mount/4` (Tasks 1–2) and the controller (Task 4). `doc_type` strings (`"Invoice"`, `"Receipt"`, `"CreditNote"`, `"DebitNote"`, `"Delivery"`, `"Order"`) are identical across the registry table, the controller `@doc_types` map, the router routes, and the `email_doc` assigns.

**Scope:** One cohesive feature, one plan.
