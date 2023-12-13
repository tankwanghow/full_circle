defmodule FullCircleWeb.ReportLive.Account do
  use FullCircleWeb, :live_view

  alias FullCircle.{Reporting, Accounting}

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(page_title: "Account Transactions")

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    params = params["search"]

    name = params["name"] || ""
    f_date = params["f_date"] || Timex.shift(Timex.today(), months: -1)
    t_date = params["t_date"] || Timex.today()

    {:noreply,
     socket
     |> assign(search: %{name: name, f_date: f_date, t_date: t_date})
     |> filter_transactions(name, f_date, t_date)}
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
      "/companies/#{socket.assigns.current_company.id}/account_transactions?#{URI.encode_query(qry)}"

    {:noreply,
     socket
     |> push_patch(to: url)}
  end

  defp filter_transactions(socket, name, f_date, t_date) do
    objects =
      if String.trim(name) == "" or f_date == "" or t_date == "" do
        []
      else
        account =
          Accounting.get_account_by_name(
            name,
            socket.assigns.current_company,
            socket.assigns.current_user
          )

        if !is_nil(account) do
          Reporting.account_transactions(
            account,
            Date.from_iso8601!(f_date),
            Date.from_iso8601!(t_date),
            socket.assigns.current_company
          )
        else
          []
        end
      end

    socket
    |> assign(objects: objects)
    |> assign(objects_count: Enum.count(objects))
    |> assign(
      objects_balance:
        Enum.reduce(objects, Decimal.new("0"), fn obj, acc -> Decimal.add(obj.amount, acc) end)
    )
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="w-11/12 mx-auto">
      <p class="text-2xl text-center font-medium"><%= "#{@page_title}" %></p>
      <div class="border rounded bg-purple-200 text-center p-2">
        <.form for={%{}} id="search-form" phx-submit="query" autocomplete="off">
          <div class="grid grid-cols-12 tracking-tighter">
            <div class="col-span-6">
              <.input
                label={gettext("Account")}
                id="search_name"
                name="search[name]"
                value={@search.name}
                phx-hook="tributeAutoComplete"
                phx-debounce="500"
                url={"/api/companies/#{@current_company.id}/#{@current_user.id}/autocomplete?schema=account&name="}
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
                :if={@objects_count > 0}
                class="blue button mr-1"
                navigate={
                  ~p"/companies/#{@current_company.id}/print/transactions?report=actrans&name=#{@search.name}&fdate=#{@search.f_date}&tdate=#{@search.t_date}"
                }
                target="_blank"
              >
                Print
              </.link>

              <.link
                :if={@objects_count > 0}
                navigate={
                  ~p"/companies/#{@current_company.id}/csv?report=actrans&name=#{@search.name}&fdate=#{@search.f_date}&tdate=#{@search.t_date}"
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
          <%= for obj <- @objects do %>
            <div class="flex flex-row text-center tracking-tighter">
              <p class="hidden"><%= obj.inserted_at %></p>
              <div class="w-[10%] border rounded bg-blue-200 border-blue-400 px-2 py-1">
                <%= obj.doc_date |> FullCircleWeb.Helpers.format_date() %>
              </div>
              <div class="w-[12%] border rounded bg-blue-200 border-blue-400 px-2 py-1">
                <%= if obj.old_data do %>
                  <.update_seed_link
                    doc_obj={obj}
                    current_company={@current_company}
                    current_user={@current_user}
                  />
                <% else %>
                  <.doc_link current_company={@current_company} doc_obj={obj} />
                <% end %>
              </div>
              <div class="w-[12%] border rounded bg-blue-200 border-blue-400 px-2 py-1">
                <%= obj.doc_type %>
              </div>
              <div class="w-[40%] border rounded bg-blue-200 border-blue-400 px-2 py-1">
                <%= obj.particulars %>
              </div>
              <div class="w-[13%] border rounded bg-blue-200 border-blue-400 px-2 py-1">
                <%= if(Decimal.gt?(obj.amount, 0), do: obj.amount, else: nil)
                |> Number.Delimit.number_to_delimited() %>
              </div>
              <div class="w-[13%] border rounded bg-blue-200 border-blue-400 px-2 py-1">
                <%= if(Decimal.gt?(obj.amount, 0), do: nil, else: Decimal.abs(obj.amount))
                |> Number.Delimit.number_to_delimited() %>
              </div>
            </div>
          <% end %>
        </div>
      </div>
      <div id="footer">
        <div class="flex flex-row text-center tracking-tighter mb-5 mt-1">
          <div class="w-[74%] border px-2 py-1 text-right font-bold rounded bg-cyan-200 border-cyan-400">
            <%= gettext("Balance") %>
          </div>
          <div class="w-[13%] font-bold border rounded bg-cyan-200 border-cyan-400 px-2 py-1">
            <%= if(Decimal.gt?(@objects_balance, 0), do: @objects_balance, else: nil)
            |> Number.Delimit.number_to_delimited() %>
          </div>
          <div class="w-[13%] font-bold border rounded bg-cyan-200 border-cyan-400 px-2 py-1">
            <%= if(Decimal.gt?(@objects_balance, 0), do: nil, else: Decimal.abs(@objects_balance))
            |> Number.Delimit.number_to_delimited() %>
          </div>
        </div>
      </div>
    </div>
    """
  end
end
