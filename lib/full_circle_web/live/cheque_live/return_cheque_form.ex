defmodule FullCircleWeb.ChequeLive.ReturnChequeForm do
  use FullCircleWeb, :live_view

  alias FullCircle.{Cheque, Reporting}
  alias FullCircle.Cheque.ReturnCheque
  alias FullCircle.StdInterface

  @impl true
  def mount(params, _session, socket) do
    id = params["return_id"]

    socket =
      case socket.assigns.live_action do
        :new -> mount_new(socket)
        :edit -> mount_edit(socket, id)
      end

    {:ok,
     socket
     |> assign(qry_cheques: [])}
  end

  defp mount_new(socket) do
    socket
    |> assign(live_action: :new)
    |> assign(id: "new")
    |> assign(page_title: gettext("New ReturnCheque"))
    |> assign(
      :form,
      to_form(
        StdInterface.changeset(
          ReturnCheque,
          %ReturnCheque{},
          %{"return_no" => "...new...", "return_date" => Timex.today()},
          socket.assigns.current_company
        )
      )
    )
  end

  defp mount_edit(socket, id) do
    object =
      Cheque.get_return_cheque!(
        id,
        socket.assigns.current_company,
        socket.assigns.current_user
      )

    cs = ReturnCheque.changeset(object, %{})

    socket
    |> assign(live_action: :edit)
    |> assign(id: id)
    |> assign(page_title: gettext("Edit Return Cheque") <> " " <> object.return_no)
    |> assign(:form, to_form(cs))
  end

  @impl true
  def handle_event(
        "validate",
        %{"return_cheque" => params},
        socket
      ) do
    validate(params, socket)
  end

  @impl true
  def handle_event("select_chq", %{"chq-id" => id}, socket) do
    chq =
      socket.assigns.qry_cheques
      |> Enum.find(fn x -> x.id == id end)

    cs = socket.assigns.form.source

    attrs =
      %{
        "return_no" => Ecto.Changeset.fetch_field!(cs, :return_no),
        "return_date" => Ecto.Changeset.fetch_field!(cs, :return_date),
        "company_id" => socket.assigns.current_company.id,
        "return_reason" => Ecto.Changeset.fetch_field!(cs, :return_reason),
        "return_from_bank_name" => chq.deposit_bank_name,
        "return_from_bank_id" => chq.deposit_bank_id,
        "cheque_owner_name" => chq.contact_name,
        "cheque_owner_id" => chq.contact_id,
        "cheque_no" => chq.cheque_no,
        "cheque_due_date" => chq.due_date,
        "cheque_amount" => chq.amount,
        "cheque" => %{"id" => id}
      }

    validate(attrs, socket)
  end

  @impl true
  def handle_event("save", %{"return_cheque" => params}, socket) do
    save(socket, socket.assigns.live_action, params)
  end

  @impl true
  def handle_event("find_chqs", %{"d_date" => d_date}, socket) do
    {:noreply, socket |> find_qry_cheques(d_date)}
  end

  defp save(socket, :new, params) do
    case FullCircle.Cheque.create_return_cheque(
           params,
           socket.assigns.current_company,
           socket.assigns.current_user
         ) do
      {:ok, %{create_return_cheque: obj}} ->
        {:noreply,
         socket
         |> push_navigate(
           to: ~p"/companies/#{socket.assigns.current_company.id}/ReturnCheque/#{obj.id}/edit"
         )
         |> put_flash(:info, "#{gettext("Create Return Cheque successfully.")}")}

      {:error, failed_operation, changeset, _} ->
        {:noreply,
         socket
         |> assign(form: to_form(changeset))
         |> put_flash(
           :error,
           "#{gettext("Failed")} #{failed_operation}. #{list_errors_to_string(changeset.errors)}"
         )}

      :not_authorise ->
        {:noreply,
         socket
         |> put_flash(:error, gettext("You are not authorised to perform this action"))}
    end
  end

  defp save(socket, :edit, params) do
    case FullCircle.Cheque.update_return_cheque(
           socket.assigns.form.source.data,
           params,
           socket.assigns.current_company,
           socket.assigns.current_user
         ) do
      {:ok, %{update_return_cheque: obj}} ->
        {:noreply,
         socket
         |> push_navigate(
           to: ~p"/companies/#{socket.assigns.current_company.id}/ReturnCheque/#{obj.id}/edit"
         )
         |> put_flash(:info, "#{gettext("Update Return Cheque successfully.")}")}

      {:error, failed_operation, changeset, _} ->
        {:noreply,
         socket
         |> assign(form: to_form(changeset))
         |> put_flash(
           :error,
           "#{gettext("Failed")} #{failed_operation}. #{list_errors_to_string(changeset.errors)}"
         )}

      :not_authorise ->
        {:noreply,
         socket
         |> put_flash(:error, gettext("You are not authorised to perform this action"))}
    end
  end

  defp find_qry_cheques(socket, d_date) do
    qry_cheques =
      Reporting.post_dated_cheques(
        "",
        "Can-Be-Return",
        "",
        d_date,
        socket.assigns.current_company
      )

    socket |> assign(qry_cheques: qry_cheques)
  end

  defp found_in_chqs?(source, id) do
    chq = Ecto.Changeset.fetch_field!(source, :cheque) || %{id: ""}
    chq.id == id
  end

  defp validate(params, socket) do
    dep_cs =
      ReturnCheque.changeset(socket.assigns.form.data, params)
      |> Map.merge(%{action: socket.assigns.live_action})

    socket = assign(socket, form: to_form(dep_cs))

    {:noreply, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="w-8/12 mx-auto border rounded-lg border-yellow-500 bg-yellow-100 p-4">
      <p class="w-full text-3xl text-center font-medium"><%= @page_title %></p>
      <.form for={@form} id="object-form" autocomplete="off" phx-change="validate" phx-submit="save">
        <%= Phoenix.HTML.Form.hidden_input(@form, :return_no) %>
        <div class="flex flex-row flex-nowarp gap-1">
          <div class="w-2/12">
            <.input
              feedback={true}
              field={@form[:return_date]}
              label={gettext("Return Date")}
              type="date"
            />
          </div>
          <div class="w-4/12">
            <.input field={@form[:return_reason]} label={gettext("Return Reason")} />
          </div>
        </div>
        <div class="flex flex-row flex-nowarp gap-1">
          <div class="w-4/12">
            <.input field={@form[:cheque_owner_name]} label={gettext("Cheque Owner")} readonly />
          </div>
          <div class="w-4/12">
            <.input
              field={@form[:return_from_bank_name]}
              label={gettext("Return From Bank")}
              readonly
            />
          </div>
          <div class="w-2/12 grow shrink">
            <.input field={@form[:cheque_no]} label={gettext("Cheque No")} readonly />
          </div>
          <div class="w-2/12 grow shrink">
            <.input
              field={@form[:cheque_due_date]}
              label={gettext("Cheque Due Date")}
              type="date"
              readonly
            />
          </div>
          <div class="w-2/12 grow shrink">
            <.input
              field={@form[:cheque_amount]}
              label={gettext("Cheque Amount")}
              type="number"
              readonly
            />
          </div>

          <%= Phoenix.HTML.Form.hidden_input(@form, :cheque_owner_id) %>
          <%= Phoenix.HTML.Form.hidden_input(@form, :return_from_bank_id) %>
          <%= Phoenix.HTML.Form.hidden_input(@form, :company_id) %>
          <.inputs_for :let={dtl} field={@form[:cheque]}>
            <%= Phoenix.HTML.Form.hidden_input(dtl, :id) %>
          </.inputs_for>
        </div>

        <div class="flex justify-center gap-x-1 mt-1">
          <.button disabled={!@form.source.valid?}><%= gettext("Save") %></.button>
          <.link :if={@live_action != :new} navigate="" class="orange_button">
            <%= gettext("Cancel") %>
          </.link>
          <a onclick="history.back();" class="blue_button"><%= gettext("Back") %></a>
          <.link
            :if={@live_action == :edit}
            navigate={~p"/companies/#{@current_company.id}/ReturnCheque/new"}
            class="blue_button"
          >
            <%= gettext("New") %>
          </.link>
          <.print_button
            :if={@live_action == :edit}
            company={@current_company}
            doc_type="ReturnCheque"
            doc_id={@id}
            class="gray_button"
          />
          <.pre_print_button
            :if={@live_action == :edit}
            company={@current_company}
            doc_type="ReturnCheque"
            doc_id={@id}
            class="gray_button"
          />
          <.live_component
            :if={@live_action == :edit}
            module={FullCircleWeb.LogLive.Component}
            id={"log_#{@id}"}
            show_log={false}
            entity="return_cheques"
            entity_id={@id}
          />
          <.live_component
            :if={@live_action == :edit}
            module={FullCircleWeb.JournalEntryViewLive.Component}
            id={"journal_#{@id}"}
            show_journal={false}
            doc_type="ReturnCheque"
            doc_no={@form.data.return_no}
            company_id={@current_company.id}
          />
        </div>
      </.form>
    </div>

    <div class="text-center w-8/12 mx-auto border rounded-lg border-blue-500 bg-blue-100 p-4">
      <div class="mb-2">
        <.link
          phx-click={:find_chqs}
          phx-value-d_date={Ecto.Changeset.fetch_field!(@form.source, :return_date)}
          class="text-lg hover:font-bold text-blue-600"
        >
          <%= gettext("Show Returnable Cheques") %>
          <%= Ecto.Changeset.fetch_field!(@form.source, :return_date)
          |> FullCircleWeb.Helpers.format_date() %>
        </.link>
      </div>

      <div class="text-center font-medium flex flex-row tracking-tighter bg-amber-200 border-amber-400 border-y-2">
        <div class="w-[12%] px-2 py-1">
          <%= gettext("Deposit Date") %>
        </div>
        <div class="w-[24%] px-2 py-1">
          <%= gettext("To Bank") %>
        </div>
        <div class="w-[24%] px-2 py-1">
          <%= gettext("Customer") %>
        </div>
        <div class="w-[10%] px-2 py-1">
          <%= gettext("Bank") %>
        </div>
        <div class="w-[10%] px-2 py-1 ">
          <%= gettext("Chq No") %>
        </div>
        <div class="w-[12%] px-2 py-1 ">
          <%= gettext("Due Date") %>
        </div>
        <div class="w-[18%] px-2 py-1">
          <%= gettext("Amount") %>
        </div>
        <div class="w-[3%]" />
      </div>

      <div class="bg-gray-50">
        <%= for obj <- @qry_cheques do %>
          <div class="flex flex-row border-b bg-gray-200 border-gray-400 text-center">
            <div class="border w-[12%] px-1 py-1">
              <span><%= obj.deposit_date %></span>
            </div>
            <div class="border w-[24%] px-1 py-1">
              <span><%= obj.deposit_bank_name %></span>
            </div>
            <div class="border w-[24%] px-1 py-1">
              <span><%= obj.contact_name %></span>
            </div>
            <div class="border w-[10%] px-1 py-1">
              <%= obj.bank %>
            </div>
            <div class="border w-[10%] px-1 py-1">
              <%= obj.cheque_no %>
            </div>
            <div class="border w-[12%] px-1 py-1">
              <%= obj.due_date %>
            </div>
            <div class="border w-[18%] px-1 py-1">
              <%= obj.amount |> Number.Delimit.number_to_delimited() %>
            </div>
            <div class="border w-[3%]  cursor-pointer">
              <.link
                :if={!found_in_chqs?(@form.source, obj.id)}
                phx-click={:select_chq}
                phx-value-chq-id={obj.id}
                tabindex="-1"
              >
                <.icon name="hero-arrow-uturn-left" class="text-orange-500 h-5 w-5" />
              </.link>
            </div>
          </div>
        <% end %>
      </div>
    </div>
    """
  end
end
