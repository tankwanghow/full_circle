defmodule FullCircleWeb.ReportLive.Contact do
  use FullCircleWeb, :live_view

  alias FullCircle.{Reporting, Accounting}

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(page_title: "Contact Transactions")
      |> assign(result: waiting_for_async_action_map())

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    params = params["search"]

    name = params["name"] || ""
    f_date = params["f_date"] || ""
    t_date = params["t_date"] || ""

    socket = socket |> assign(search: %{name: name, f_date: f_date, t_date: t_date})

    {:noreply,
     if String.trim(name) == "" or f_date == "" or t_date == "" do
       socket
     else
       socket |> filter_transactions(name, f_date, t_date)
     end}
  end

  @impl true
  def handle_event("changed", _, socket) do
    {:noreply,
     socket
     |> assign(result: waiting_for_async_action_map())}
  end

  @impl true
  def handle_event(
        "query",
        %{
          "search" => %{
            "name" => name,
            "f_date" => f_date,
            "t_date" => t_date
          }
        },
        socket
      ) do
    qry = %{
      "search[name]" => name,
      "search[f_date]" => f_date,
      "search[t_date]" => t_date
    }

    url =
      "/companies/#{socket.assigns.current_company.id}/contact_transactions?#{URI.encode_query(qry)}"

    {:noreply,
     socket
     |> push_navigate(to: url)}
  end

  defp filter_transactions(socket, name, f_date, t_date) do
    current_company = socket.assigns.current_company

    account =
      Accounting.get_contact_by_name(
        name,
        current_company,
        socket.assigns.current_user
      )

    socket
    |> assign_async(
      :result,
      fn ->
        {:ok,
         %{
           result:
             if !is_nil(account) do
               Reporting.contact_transactions(
                 account,
                 Date.from_iso8601!(f_date),
                 Date.from_iso8601!(t_date),
                 current_company
               )
             else
               []
             end
         }}
      end
    )
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="w-11/12 mx-auto">
      <p class="text-2xl text-center font-medium"><%= "#{@page_title}" %></p>
      <div class="border rounded bg-amber-200 text-center p-2">
        <.form for={%{}} id="search-form" phx-change="changed" phx-submit="query" autocomplete="off">
          <div class="grid grid-cols-12 tracking-tighter">
            <div class="col-span-6">
              <.input
                label={gettext("Contact")}
                id="search_name"
                name="search[name]"
                value={@search.name}
                phx-hook="tributeAutoComplete"
                url={"/api/companies/#{@current_company.id}/#{@current_user.id}/autocomplete?schema=contact&name="}
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
              <.button>
                <%= gettext("Query") %>
              </.button>
              <.link
                :if={@result.ok? and Enum.count(@result.result) > 0}
                class="blue button mr-1"
                navigate={
                  ~p"/companies/#{@current_company.id}/print/transactions?report=contacttrans&name=#{@search.name}&fdate=#{@search.f_date}&tdate=#{@search.t_date}"
                }
                target="_blank"
              >
                Print
              </.link>
              <.link
                :if={@result.ok? and Enum.count(@result.result) > 0}
                navigate={
                  ~p"/companies/#{@current_company.id}/csv?report=contacttrans&name=#{@search.name}&fdate=#{@search.f_date}&tdate=#{@search.t_date}"
                }
                class="blue button"
                target="_blank"
              >
                CSV
              </.link>
            </div>
          </div>
        </.form>
      </div>
      <.async_html result={@result}>
        <:result_html>
          <% objects_balance =
            Enum.reduce(@result.result, Decimal.new("0"), fn obj, acc ->
              Decimal.add(obj.amount, acc)
            end) %>
          <div class="font-medium flex flex-row text-center tracking-tighter mb-1">
            <div class="w-[10%] border rounded bg-gray-200 border-gray-400 px-2 py-1">
              <%= gettext("Date") %>
            </div>
            <div class="w-[12%] border rounded bg-gray-200 border-gray-400 px-2 py-1">
              <%= gettext("Doc No") %>
            </div>
            <div class="w-[12%] border rounded bg-gray-200 border-gray-400 px-2 py-1">
              <%= gettext("Doc Type") %>
            </div>
            <div class="w-[40%] border rounded bg-gray-200 border-gray-400 px-2 py-1">
              <%= gettext("Particulars") %>
            </div>
            <div class="w-[13%] border rounded bg-gray-200 border-gray-400 px-2 py-1">
              <%= gettext("Debit") %>
            </div>
            <div class="w-[13%] border rounded bg-gray-200 border-gray-400 px-2 py-1">
              <%= gettext("Credit") %>
            </div>
          </div>
          <div class=" bg-gray-50">
            <div id="transactions">
              <%= for obj <- @result.result do %>
                <div class="flex flex-row text-center tracking-tighter">
                  <p class="hidden"><%= obj.inserted_at %></p>
                  <div class="w-[10%] border rounded bg-green-200 border-green-400 px-2 py-1">
                    <%= obj.doc_date |> FullCircleWeb.Helpers.format_date() %>
                  </div>
                  <div class="w-[12%] border rounded bg-green-200 border-green-400 px-2 py-1">
                    <%= if obj.old_data do %>
                      <.update_seed_link
                        doc_obj={obj}
                        current_company={@current_company}
                        current_role={@current_role}
                      />
                    <% else %>
                      <.doc_link current_company={@current_company} doc_obj={obj} />
                    <% end %>
                  </div>
                  <div class="w-[12%] border rounded bg-green-200 border-green-400 px-2 py-1">
                    <%= obj.doc_type %>
                  </div>
                  <div class="w-[40%] border rounded bg-green-200 border-green-400 px-2 py-1">
                    <%= obj.particulars %>
                  </div>
                  <div class="w-[13%] border rounded bg-green-200 border-green-400 px-2 py-1">
                    <%= if(Decimal.gt?(obj.amount, 0), do: obj.amount, else: nil)
                    |> Number.Delimit.number_to_delimited() %>
                  </div>
                  <div class="w-[13%] border rounded bg-green-200 border-green-400 px-2 py-1">
                    <%= if(Decimal.gt?(obj.amount, 0), do: nil, else: Decimal.abs(obj.amount))
                    |> Number.Delimit.number_to_delimited() %>
                  </div>
                </div>
              <% end %>
            </div>
          </div>
          <div id="footer">
            <div class="flex flex-row text-center tracking-tighter mb-5 mt-1">
              <div class="w-[74%] border px-2 py-1 text-right font-bold rounded bg-lime-200 border-lime-400">
                <%= gettext("Balance") %>
              </div>
              <div class="w-[13%] font-bold border rounded bg-lime-200 border-lime-400 px-2 py-1">
                <%= if(Decimal.gt?(objects_balance, 0), do: objects_balance, else: nil)
                |> Number.Delimit.number_to_delimited() %>
              </div>
              <div class="w-[13%] font-bold border rounded bg-lime-200 border-lime-400 px-2 py-1">
                <%= if(Decimal.gt?(objects_balance, 0), do: nil, else: Decimal.abs(objects_balance))
                |> Number.Delimit.number_to_delimited() %>
              </div>
            </div>
          </div>
        </:result_html>
      </.async_html>
    </div>
    """
  end
end
