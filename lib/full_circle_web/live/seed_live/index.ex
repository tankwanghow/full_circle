defmodule FullCircleWeb.SeedLive.Index do
  use FullCircleWeb, :live_view
  alias Phoenix.PubSub

  @seed_tables %{
    "--Select One--" => ~w(),
    "FixedAssets" =>
      ~w(name pur_date pur_price descriptions depre_start_date residual_value depre_method depre_rate asset_ac_name depre_ac_name disp_fund_ac_name depre_interval),
    "Accounts" => ~w(account_type name descriptions),
    "TaxCodes" => ~w(code tax_type rate descriptions account_name),
    "Contacts" =>
      ~w(name address1 address2 city zipcode state country reg_no email contact_info descriptions),
    "Goods" =>
      ~w(name descriptions unit purchase_account_name sales_account_name purchase_tax_code_name sales_tax_code_name)
  }

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      PubSub.subscribe(FullCircle.PubSub, "seed_data_changeset_generation_progress")
      PubSub.subscribe(FullCircle.PubSub, "seed_data_changeset_generation_finished")
    end

    socket =
      socket
      |> assign(page_title: gettext("Seeding Database"))
      |> assign(seed_tables: Map.keys(@seed_tables))
      |> assign(seed_table: Map.keys(@seed_tables) |> Enum.at(0))
      |> assign(
        seed_table_headers: Map.fetch!(@seed_tables, Map.keys(@seed_tables) |> Enum.at(0))
      )
      |> assign(status: "")
      |> assign(status_flag: :info)
      |> assign(attrs: [])
      |> assign(csv_headers: [])
      |> assign(cs_has_error?: true)
      |> allow_upload(:csv_file,
        accept: ~w(.csv),
        max_file_size: 1_000_000,
        progress: &handle_progress/3,
        auto_upload: true
      )

    {:ok, socket}
  end

  defp reset_form(socket) do
    socket
    |> assign(seed_table: Map.keys(@seed_tables) |> Enum.at(0))
    |> assign(seed_table_headers: Map.fetch!(@seed_tables, Map.keys(@seed_tables) |> Enum.at(0)))
    |> assign(attrs: [])
    |> assign(csv_headers: [])
    |> assign(cs_has_error?: true)
  end

  @impl true
  def handle_event("start_seed", %{"seed_table" => val}, socket) do
    case FullCircle.Seeding.seed(
           val,
           socket.assigns.attrs,
           socket.assigns.current_company,
           socket.assigns.current_user
         ) do
      {:ok, _cs} ->
        {:noreply,
         socket
         |> assign(status: "Seeding #{val} Database Done!!")
         |> assign(status_flag: :success)
         |> reset_form()}

      {:error, msg} ->
        {:noreply,
         socket
         |> assign(status: "Seeding #{val} Database Failed!! #{inspect(msg)}")
         |> assign(status_flag: :error)}

      :not_authorise ->
        {:noreply,
         socket
         |> assign(status: "You are not authorise!!")
         |> assign(status_flag: :error)}
    end
  end

  @impl true
  def handle_event("validate", %{"_target" => ["seed_table"], "seed_table" => params}, socket) do
    {:noreply,
     socket
     |> assign(seed_table: params)
     |> assign(status: "")
     |> assign(attrs: [])
     |> assign(csv_headers: [])
     |> assign(seed_table_headers: Map.fetch!(@seed_tables, params))}
  end

  @impl true
  def handle_event("validate", _params, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_info({:update_progress, data}, socket) do
    {:noreply,
     socket
     |> assign(status: "Seed Generating...#{data.progress}")
     |> assign(status_flag: :loading)}
  end

  @impl true
  def handle_info({:finish, data}, socket) do
    {:noreply,
     socket
     |> assign(attrs: data.cs)
     |> assign(status: if(data.cs_has_error, do: "Seeding CSV file has error!!", else: "Done"))
     |> assign(status_flag: if(data.cs_has_error, do: :error, else: :success))
     |> assign(cs_has_error?: data.cs_has_error)}
  end

  def handle_progress(:csv_file, entry, socket) do
    if entry.done? do
      attrs =
        consume_uploaded_entry(socket, entry, fn %{path: path} ->
          {:ok, csv_to_attrs(path)}
        end)

      csv_headers = attrs |> Enum.at(0) |> Map.keys()

      if check_header_name?(csv_headers, socket.assigns.seed_table_headers) do
        Task.start(fn ->
          {cs_attrs, _} =
            Enum.map_reduce(attrs, 0, fn attr, acc ->
              if(rem(trunc(acc / Enum.count(attrs) * 100), 5) == 0) do
                Phoenix.PubSub.broadcast(
                  FullCircle.PubSub,
                  "seed_data_changeset_generation_progress",
                  {:update_progress,
                   %{
                     progress:
                       (acc / Enum.count(attrs) * 100) |> Number.Percentage.number_to_percentage()
                   }}
                )
              end

              cs =
                FullCircle.Seeding.fill_changeset(
                  socket.assigns.seed_table,
                  attr,
                  socket.assigns.current_company,
                  socket.assigns.current_user
                )

              {cs, acc + 1}
            end)

          cs_has_error =
            if cs_attrs |> Enum.find(fn x -> !x.valid? end) |> is_nil() do
              false
            else
              true
            end

          Phoenix.PubSub.broadcast(
            FullCircle.PubSub,
            "seed_data_changeset_generation_finished",
            {:finish, %{cs: cs_attrs, cs_has_error: cs_has_error}}
          )
        end)

        {:noreply,
         socket
         |> assign(status: "uploaded!")
         |> assign(status_flag: :success)
         |> assign(csv_headers: csv_headers)}
      else
        {:noreply,
         socket
         |> assign(attrs: [])
         |> assign(status: "header error!")
         |> assign(status_flag: :error)}
      end
    else
      {:noreply, assign(socket, status: "uploading...") |> assign(status_flag: :loading)}
    end
  end

  defp check_header_name?(headers, header_required) do
    Enum.map(headers, fn h ->
      Enum.find(
        header_required,
        fn x -> x == h end
      )
    end) == headers
  end

  defp csv_to_attrs(path) do
    File.stream!(path)
    |> NimbleCSV.RFC4180.parse_stream(skip_headers: false)
    |> Stream.transform(nil, fn
      headers, nil -> {[], headers}
      row, headers -> {[Enum.zip(headers, row) |> Map.new()], headers}
    end)
    |> Enum.to_list()
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="max-w-full w-full text-center">
      <p class="text-3xl font-medium"><%= @page_title %></p>
      <.form
        for={%{}}
        id="object-form"
        autocomplete="off"
        phx-change="validate"
        phx-submit="start_seed"
        class="p-4 mb-1 border rounded-lg border-blue-500 bg-blue-200"
      >
        <div class="flex flex-row flex-nowarp mb-2">
          <div class="p-2">Seed</div>
          <.input name="seed_table" value={@seed_table} type="select" options={@seed_tables} />
          <div class="p-2">using</div>

          <div :if={@seed_table != "--Select One--"} class="p-2">
            <.live_file_input upload={@uploads.csv_file} />
          </div>
        </div>
        <div class="mb-1 rounded-lg p-2 bg-yellow-200 border border-yellow-500 font-semibold text-center">
          <p>
            <%= "Maximum file size is #{(@uploads.csv_file.max_file_size / 1_000_000) |> trunc} MB" %>
          </p>
          <span
            :for={{_, msg} <- @uploads.csv_file.errors}
            class="text-center font-bold text-rose-500"
          >
            <%= msg %>
          </span>

          <div class={[
            "text-xl",
            @status_flag == :error && "text-rose-500",
            @status_flag == :loading && "text-yellow-500",
            @status_flag == :info && "text-purple-500",
            @status_flag == :success && "text-green-500"
          ]}>
            <%= @status %>
          </div>
          <%= for entry <- @uploads.csv_file.entries do %>
            <%= entry.progress %>%
          <% end %>
        </div>

        <div class="border rounded-lg bg-gray-200 border-gray-500 p-2 mb-1">
          <div class="p-2">
            CSV file require
            <headers></headers>
            below.
          </div>
          <div class="font-bold font-mono text-amber-600">
            <%= Enum.join(@seed_table_headers, ", ") %>
          </div>
        </div>
        <.button :if={@uploads.csv_file.errors == [] && !@cs_has_error?}>
          <%= gettext("Start Seed") %>
        </.button>
      </.form>
      <table :if={Enum.count(@attrs) > 0} class="table-auto">
        <tr>
          <%= for header <- @csv_headers ++ ["seed status"] do %>
            <th class="border border-gray-600 bg-gray-200 px-2">
              <%= header %>
            </th>
          <% end %>
        </tr>

        <%= for a <- @attrs do %>
          <tr>
            <%= for h <- @csv_headers do %>
              <td class={[
                "border border-gray-600 px-2",
                a.errors == [] && "bg-green-200",
                a.errors != [] && "bg-rose-200"
              ]}>
                <%= Ecto.Changeset.fetch_field!(a, String.to_atom(h)) %>
              </td>
            <% end %>
            <td class={[
              "border border-gray-600 px-2",
              a.errors == [] && "bg-green-200",
              a.errors != [] && "bg-rose-200"
            ]}>
              <%= if(a.errors != [], do: inspect(a.errors), else: "ok") %>
            </td>
          </tr>
        <% end %>
      </table>
    </div>
    """
  end
end