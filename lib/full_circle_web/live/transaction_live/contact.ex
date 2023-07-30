defmodule FullCircleWeb.TransactionLive.Contact do
  use FullCircleWeb, :live_view

  alias FullCircle.{Reporting, Accounting}

  @impl true
  def mount(_params, _session, socket) do
    objects = []

    socket =
      socket
      |> assign(contact_names: [])
      |> assign(page_title: "Contact Transactions")
      |> assign(search: %{name: "", f_date: Date.utc_today(), t_date: Date.utc_today()})
      |> assign(:objects, objects)
      |> assign(valid?: false)
      |> assign(objects_count: 0)
      |> assign(objects_balance: Decimal.new("0"))
      |> assign(live_action: nil)

    {:ok, socket}
  end

  @impl true
  def handle_event("query", _, socket) do
    {:noreply, socket |> filter_transactions()}
  end

  @impl true
  def handle_event(
        "validate",
        %{"_target" => ["search", _], "search" => params},
        socket
      ) do
    {l, v} =
      FullCircleWeb.Helpers.list_n_value(socket, params["name"], &Accounting.contact_names/3)

    socket =
      socket
      |> assign(
        contact: if(v, do: FullCircle.StdInterface.get!(Accounting.Contact, v.id), else: nil)
      )
      |> assign(contact_names: l)
      |> assign(
        search: %{name: params["name"], f_date: params["f_date"], t_date: params["t_date"]}
      )
      |> assign(valid?: !is_nil(v) and params["f_date"] != "" and params["t_date"] != "")

    {:noreply, socket}
  end

  @impl true
  def handle_event("modal_cancel", _, socket) do
    {:noreply, socket |> assign(live_action: nil)}
  end

  defp filter_transactions(socket) do
    objects =
      Reporting.contact_transactions(
        socket.assigns.contact,
        Date.from_iso8601!(socket.assigns.search.f_date),
        Date.from_iso8601!(socket.assigns.search.t_date),
        socket.assigns.current_company
      )

    socket
    |> assign(:objects, objects)
    |> assign(objects_count: Enum.count(objects))
    |> assign(
      objects_balance:
        Enum.reduce(objects, Decimal.new("0"), fn obj, acc -> Decimal.add(obj.amount, acc) end)
    )
  end

  ######################################
  @impl true
  def handle_info({:show_form, map}, socket) do
    socket = socket |> assign(map)
    {:noreply, socket |> assign(live_action: :edit)}
  end

  @impl true
  def handle_info({:updated, _obj}, socket) do
    {:noreply,
     socket
     |> assign(live_action: nil)
     |> filter_transactions()
     |> put_flash(
       :info,
       "#{gettext("Updated successfully.")}"
     )}
  end

  @impl true
  def handle_info({:error, failed_operation, failed_value}, socket) do
    {:noreply,
     socket
     |> assign(live_action: nil)
     |> put_flash(
       :error,
       "#{gettext("Failed")} #{failed_operation}. #{list_errors_to_string(failed_value.errors)}"
     )}
  end

  @impl true
  def handle_info(:not_authorise, socket) do
    {:noreply,
     socket
     |> assign(live_action: nil)
     |> put_flash(:error, gettext("You are not authorised to perform this action"))}
  end

  @impl true
  def handle_info({:sql_error, msg}, socket) do
    {:noreply,
     socket
     |> assign(live_action: nil)
     |> put_flash(:error, msg)}
  end

  ######################################

  @impl true
  def render(assigns) do
    ~H"""
    <div class="w-11/12 mx-auto">
      <p class="text-2xl text-center font-medium"><%= "#{@page_title}" %></p>
      <div class="border rounded bg-amber-200 text-center p-2">
        <.form for={%{}} id="search-form" phx-submit="query" autocomplete="off" phx-change="validate">
          <div class="grid grid-cols-12 tracking-tighter">
            <div class="col-span-6">
              <.input
                label={gettext("Contact")}
                id="search_name"
                name="search[name]"
                list="contact_names"
                value={@search.name}
              />
            </div>
            <div class="col-span-2">
              <.input
                label={gettext("From")}
                name="search[f_date]"
                type="date"
                id="search_f_date"
                value={@search.f_date}
              />
            </div>
            <div class="col-span-2">
              <.input
                label={gettext("To")}
                name="search[t_date]"
                type="date"
                id="search_t_date"
                value={@search.t_date}
              />
            </div>
            <div class="col-span-2 mt-6">
              <.button disabled={!@valid?}>
                <%= gettext("Query") %>
              </.button>
              <.link
                :if={@objects_count > 0}
                class="blue_button mr-1"
                patch={
                  ~p"/companies/#{@current_company.id}/print_transactions?report=contacttrans&name=#{@search.name}&fdate=#{@search.f_date}&tdate=#{@search.t_date}"
                }
                target="_blank"
              >
                Print
              </.link>
              <.link
                :if={@objects_count > 0}
                href={
                  ~p"/companies/#{@current_company.id}/csv?report=contacttrans&name=#{@search.name}&fdate=#{@search.f_date}&tdate=#{@search.t_date}"
                }
                class="blue_button"
              >
                CSV
              </.link>
            </div>
          </div>
        </.form>
      </div>

      <div class="font-medium flex flex-row text-center tracking-tighter mb-1">
        <div class="w-[8.9rem] border rounded bg-gray-200 border-gray-400 px-2 py-1">
          <%= gettext("Date") %>
        </div>
        <div class="w-[8.9rem] border rounded bg-gray-200 border-gray-400 px-2 py-1">
          <%= gettext("Doc No") %>
        </div>
        <div class="w-[8.85rem] border rounded bg-gray-200 border-gray-400 px-2 py-1">
          <%= gettext("Doc Type") %>
        </div>
        <div class="w-[44.35rem] border rounded bg-gray-200 border-gray-400 px-2 py-1">
          <%= gettext("Particulars") %>
        </div>
        <div class="w-[9.85rem] border rounded bg-gray-200 border-gray-400 px-2 py-1">
          <%= gettext("Debit") %>
        </div>
        <div class="w-[9.85rem] border rounded bg-gray-200 border-gray-400 px-2 py-1">
          <%= gettext("Credit") %>
        </div>
      </div>
      <div class="min-h-[40rem] max-h-[40rem] overflow-y-scroll bg-gray-50">
        <div id="transactions">
          <%= for obj <- @objects do %>
            <div class="flex flex-row text-center tracking-tighter">
              <p class="hidden"><%= obj.inserted_at %></p>
              <div class="w-[9rem] border rounded bg-green-200 border-green-400 text-center px-2 py-1">
                <%= obj.doc_date %>
              </div>
              <div class="w-[9rem] border rounded bg-green-200 border-green-400 text-center px-2 py-1">
                <%= if obj.old_data do %>
                  <%= obj.doc_no %>
                <% else %>
                  <.live_component
                    module={FullCircleWeb.EntityFormLive.Component}
                    id={obj.id}
                    entity={obj.doc_type}
                    live_action={@live_action}
                    doc_no={obj.doc_no}
                    current_company={@current_company}
                    current_user={@current_user}
                  />
                <% end %>
              </div>
              <div class="w-[9rem] border rounded bg-green-200 border-green-400 text-center px-2 py-1">
                <%= obj.doc_type %>
              </div>
              <div class="w-[45rem] border rounded bg-green-200 border-green-400 px-2 py-1">
                <%= obj.particulars %>
              </div>
              <div class="w-[10rem] border rounded bg-green-200 border-green-400 text-center px-2 py-1">
                <%= if(Decimal.gt?(obj.amount, 0), do: obj.amount, else: nil)
                |> Number.Delimit.number_to_delimited() %>
              </div>
              <div class="w-[10rem] border rounded bg-green-200 border-green-400 text-center px-2 py-1">
                <%= if(Decimal.gt?(obj.amount, 0), do: nil, else: Decimal.abs(obj.amount))
                |> Number.Delimit.number_to_delimited() %>
              </div>
            </div>
          <% end %>
        </div>
      </div>
      <div id="footer">
        <div class="flex flex-row text-center tracking-tighter mb-5 mt-1">
          <div class="w-[71rem] border px-2 py-1 text-right font-bold rounded bg-lime-200 border-lime-400">
            <%= gettext("Balance") %>
          </div>
          <div class="w-[9.85rem] font-bold border rounded bg-lime-200 border-lime-400 text-center px-2 py-1">
            <%= if(Decimal.gt?(@objects_balance, 0), do: @objects_balance, else: nil)
            |> Number.Delimit.number_to_delimited() %>
          </div>
          <div class="w-[9.85rem] font-bold border rounded bg-lime-200 border-lime-400 text-center px-2 py-1">
            <%= if(Decimal.gt?(@objects_balance, 0), do: nil, else: Decimal.abs(@objects_balance))
            |> Number.Delimit.number_to_delimited() %>
          </div>
        </div>
      </div>
    </div>
    <.modal
      :if={@live_action in [:new, :edit]}
      id="object-crud-modal"
      show
      max_w="max-w-full"
      on_cancel={JS.push("modal_cancel")}
    >
      <.live_component
        module={@module}
        id={@id}
        title={@title}
        live_action={@live_action}
        form={@form}
        current_company={@current_company}
        current_user={@current_user}
      />
    </.modal>
    <%= datalist_with_ids(@contact_names, "contact_names") %>
    """
  end
end
