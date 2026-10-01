defmodule FullCircleWeb.PaymentLive.IndexComponent do
  use FullCircleWeb, :live_component

  import FullCircleWeb.ListComponents
  import FullCircleWeb.EInvComponents

  alias FullCircle.EInvMetas
  alias FullCircleWeb.EInvComponents

  @impl true
  def mount(socket) do
    {:ok, socket}
  end

  @impl true
  def update(assigns, socket) do
    {:ok,
     socket
     |> assign(assigns)
     |> assign_new(:note_count, fn -> 0 end)
     |> assign_new(:einv_open, fn -> false end)
     |> get_e_invoices()}
  end

  defp get_e_invoices(socket) do
    socket
    |> assign(
      e_invs:
        EInvMetas.get_e_invs(
          socket.assigns.obj.e_inv_uuid || "",
          socket.assigns.obj.payment_no,
          socket.assigns.obj.contact_name,
          socket.assigns.obj.amount,
          socket.assigns.obj.payment_date,
          socket.assigns.company,
          socket.assigns.user
        ) || []
    )
  end

  defp refresh_self(doc_id, socket) do
    socket
    |> assign(
      obj:
        FullCircle.BillPay.get_payment_by_id_index_component_field!(
          doc_id,
          socket.assigns.company,
          socket.assigns.user
        )
    )
    |> get_e_invoices()
  end

  @impl true
  def handle_event("toggle_einv", _, socket) do
    {:noreply, update(socket, :einv_open, &(!&1))}
  end

  @impl true
  def handle_event("match", %{"einv" => einv, "fcdoc" => fc_doc}, socket) do
    einv = Jason.decode!(einv)
    fc_doc = Jason.decode!(fc_doc)

    case EInvMetas.match(
           einv,
           fc_doc,
           socket.assigns.company,
           socket.assigns.user
         ) do
      {:ok, _} ->
        {:noreply, refresh_self(fc_doc["doc_id"], socket)}

      {:error, failed_operation, changeset, _} ->
        {:noreply,
         socket
         |> assign(form: to_form(changeset))
         |> put_flash(
           :error,
           "#{gettext("Failed")} #{failed_operation}. #{list_errors_to_string(changeset.errors)}"
         )}

      {:sql_error, msg} ->
        {:noreply,
         socket
         |> put_flash(:error, "#{gettext("Failed")} #{msg}")}

      :not_authorise ->
        {:noreply,
         socket
         |> put_flash(:error, gettext("You are not authorised to perform this action"))}
    end
  end

  @impl true
  def handle_event("unmatch", %{"fcdoc" => fc_doc}, socket) do
    fc_doc = Jason.decode!(fc_doc)

    case EInvMetas.unmatch(fc_doc, socket.assigns.company, socket.assigns.user) do
      {:ok, _} ->
        {:noreply, refresh_self(fc_doc["doc_id"], socket)}

      {:error, failed_operation, changeset, _} ->
        {:noreply,
         socket
         |> assign(form: to_form(changeset))
         |> put_flash(
           :error,
           "#{gettext("Failed")} #{failed_operation}. #{list_errors_to_string(changeset.errors)}"
         )}

      {:sql_error, msg} ->
        {:noreply,
         socket
         |> put_flash(:error, "#{gettext("Failed")} #{msg}")}

      :not_authorise ->
        {:noreply,
         socket
         |> put_flash(:error, gettext("You are not authorised to perform this action"))}
    end
  end

  @impl true
  def render(assigns) do
    assigns =
      assigns
      |> assign(:state, EInvComponents.einv_state(assigns.obj.e_inv_uuid, assigns.e_invs))

    ~H"""
    <div id={@id} class={row_class(@ex_class)}>
      <div class={line_class()}>
        <div class="w-6 shrink-0 text-center">
          <%!-- Two inputs so a server-side toggle re-renders the checked state --%>
          <input
            :if={@obj.checked and !@obj.old_data}
            id={"checkbox_#{@obj.id}"}
            type="checkbox"
            class="rounded border-gray-400"
            phx-click="check_click"
            phx-value-object-id={@obj.id}
            checked
          />
          <input
            :if={!@obj.checked and !@obj.old_data}
            id={"checkbox_#{@obj.id}"}
            type="checkbox"
            class="rounded border-gray-400"
            phx-click="check_click"
            phx-value-object-id={@obj.id}
          />
        </div>

        <div class="w-24 shrink-0 tabular-nums">
          {FullCircleWeb.Helpers.format_date(@obj.payment_date)}
        </div>

        <div class="w-40 shrink-0 whitespace-nowrap overflow-hidden flex items-center gap-1">
          <%= if @obj.old_data do %>
            {@obj.payment_no}
          <% else %>
            <.link
              navigate={~p"/companies/#{@company.id}/Payment/#{@obj.id}/edit"}
              class="text-blue-600 hover:font-bold"
            >
              {@obj.payment_no}
            </.link>
            <.row_notes_badge count={@note_count} id={@obj.id} />
            <span
              :if={@obj.e_inv_internal_id && @obj.payment_no != @obj.e_inv_internal_id}
              class="min-w-0 truncate text-xs text-slate-500"
              title={@obj.e_inv_internal_id}
            >
              {@obj.e_inv_internal_id}
            </span>
          <% end %>
        </div>

        <div
          class="flex-1 min-w-0 truncate"
          title={Enum.join(Enum.reject([@obj.tax_id, @obj.reg_no], &(&1 in [nil, ""])), " · ")}
        >
          {@obj.contact_name}
        </div>

        <div class={["w-[24%] shrink-0 truncate", muted_class()]} title={@obj.particulars}>
          {@obj.particulars}
        </div>

        <.amount_cell amount={@obj.amount |> Decimal.abs()} />
        <.amount_cell amount={
          @obj.amount
          |> Decimal.sub(@obj.details_amount)
          |> Decimal.sub(@obj.tax_amount)
          |> Decimal.sub(@obj.matched_amount)
          |> Decimal.abs()
        } />

        <div class="w-36 shrink-0">
          <%= if @obj.got_details > 0 do %>
            <.einv_chip
              state={@state}
              fc={@obj}
              doc_id={@obj.id}
              copy_text={@obj.payment_no}
              none_label={gettext("Not sent")}
              einv_portal={@einv_portal}
              myself={@myself}
            />
          <% else %>
            <.chip title={gettext("No matching needed — payment to supplier")}>
              {gettext("n/a")}
            </.chip>
          <% end %>
        </div>

        <.einv_toggle :if={@obj.got_details > 0} open={@einv_open} myself={@myself} />
        <div :if={!(@obj.got_details > 0)} class="w-6 shrink-0"></div>
      </div>

      <.einv_details
        :if={@einv_open and @obj.got_details > 0}
        e_invs={@e_invs}
        fc={@obj}
        doc_id={@obj.id}
        copy_text={@obj.payment_no}
        company={@company}
        einv_portal={@einv_portal}
        myself={@myself}
      />
    </div>
    """
  end
end
