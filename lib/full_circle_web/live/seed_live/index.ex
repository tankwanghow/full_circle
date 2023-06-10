defmodule FullCircleWeb.SeedLive.Index do
  use FullCircleWeb, :live_view
  alias Phoenix.PubSub

  @seed_tables %{
    "Accounts" => ~w(),
    "TaxCodes" => ~w(code tax_type rate descriptions account_name),
    "Contacts" => ~w(),
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
      |> assign(attrs: [])
      |> assign(csv_headers: [])
      |> allow_upload(:csv_file,
        accept: ~w(.csv),
        max_file_size: 1_000_000,
        progress: &handle_progress/3,
        auto_upload: true
      )

    {:ok, socket}
  end

  @impl true
  def handle_event("seed_taxcode", _params, socket) do
    # csv_data =
    #   File.stream!(meta.path)
    #   |> NimbleCSV.RFC4180.parse_stream()
    #   |> Stream.map(fn [name, desc, unit] ->
    #     %{name: name, descriptions: desc, unit: unit}
    #   end)
    #   |> Enum.to_list()

    # consume_uploaded_entries(socket, :taxcode_file, fn meta, entry ->
    #   dest = Path.join(["priv", "static", "uploads", "#{entry.uuid}-#{entry.client_name}"])
    #   File.cp!(meta.path, dest)
    #   {:ok, static_path(socket, "/uploads/#{Path.basename(dest)}")}
    # end)

    {:noreply, socket}
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
    {:noreply, socket |> assign(status: "Seed Generating...#{data.progress}")}
  end

  @impl true
  def handle_info({:finish, data}, socket) do
    {:noreply, socket |> assign(attrs: data.cs) |> assign(status: data.status)}
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
              Phoenix.PubSub.broadcast(
                FullCircle.PubSub,
                "seed_data_changeset_generation_progress",
                {:update_progress,
                 %{
                   progress:
                     (acc / Enum.count(attrs) * 100) |> Number.Percentage.number_to_percentage()
                 }}
              )

              {fill_changeset(socket, socket.assigns.seed_table, attr), acc + 1}
            end)

          Phoenix.PubSub.broadcast(
            FullCircle.PubSub,
            "seed_data_changeset_generation_finished",
            {:finish, %{cs: cs_attrs, status: "Done!"}}
          )
        end)

        {:noreply,
         socket
         |> assign(status: "uploaded!")
         |> assign(csv_headers: csv_headers)}
      else
        {:noreply, socket |> assign(attrs: []) |> assign(status: "header error!")}
      end
    else
      {:noreply, assign(socket, status: "uploading...")}
    end
  end

  defp fill_changeset(socket, "Goods", attr) do
    pur_ac =
      FullCircle.Accounting.get_account_by_name(
        Map.fetch!(attr, "purchase_account_name"),
        socket.assigns.current_company,
        socket.assigns.current_user
      )

    sal_ac =
      FullCircle.Accounting.get_account_by_name(
        Map.fetch!(attr, "sales_account_name"),
        socket.assigns.current_company,
        socket.assigns.current_user
      )

    sal_tax =
      FullCircle.Accounting.get_tax_code_by_code(
        Map.fetch!(attr, "sales_tax_code_name"),
        socket.assigns.current_company,
        socket.assigns.current_user
      )

    pur_tax =
      FullCircle.Accounting.get_tax_code_by_code(
        Map.fetch!(attr, "purchase_tax_code_name"),
        socket.assigns.current_company,
        socket.assigns.current_user
      )

    attr =
      attr
      |> Map.merge(%{"purchase_account_id" => if(pur_ac, do: pur_ac.id, else: nil)})
      |> Map.merge(%{"sales_account_id" => if(sal_ac, do: sal_ac.id, else: nil)})
      |> Map.merge(%{"purchase_tax_code_id" => if(pur_tax, do: pur_tax.id, else: nil)})
      |> Map.merge(%{"sales_tax_code_id" => if(sal_tax, do: sal_tax.id, else: nil)})
      |> Map.merge(%{packagings: %{"0" => %{name: "-", unit_multiplier: 0, cost_per_package: 0}}})

    FullCircle.StdInterface.changeset(
      FullCircle.Product.Good,
      FullCircle.Product.Good.__struct__(),
      attr,
      socket.assigns.current_company
    )
  end

  defp fill_changeset(socket, "TaxCodes", attr) do
    account =
      FullCircle.Accounting.get_account_by_name(
        Map.fetch!(attr, "account_name"),
        socket.assigns.current_company,
        socket.assigns.current_user
      )

    attr = attr |> Map.merge(%{"account_id" => if(account, do: account.id, else: nil)})

    FullCircle.StdInterface.changeset(
      FullCircle.Accounting.TaxCode,
      FullCircle.Accounting.TaxCode.__struct__(),
      attr,
      socket.assigns.current_company
    )
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
    <div class="max-w-max mx-auto">
      <p class="w-full text-3xl text-center font-medium"><%= @page_title %></p>
      <.form
        for={%{}}
        id="object-form"
        autocomplete="off"
        phx-change="validate"
        phx-submit="seed_taxcode"
        class="p-4 mb-2 border rounded-lg border-blue-500 bg-blue-200"
      >
        <div class="flex flex-row flex-nowarp">
          <div class="p-2">Seed</div>
          <.input name="seed_table" value={@seed_table} type="select" options={@seed_tables} />
          <div class="p-2">using</div>

          <div class="p-2"><.live_file_input upload={@uploads.csv_file} /></div>
        </div>
        <div class="rounded-lg p-2 bg-yellow-200 border border-yellow-500 font-semibold text-center">
          <p>
            <%= "Maximum file size is #{(@uploads.csv_file.max_file_size / 1_000_000) |> trunc} MB" %>
          </p>
          <span
            :for={{_, msg} <- @uploads.csv_file.errors}
            class="text-center font-bold text-rose-500"
          >
            <%= msg %>
          </span>

          <%= @status %>
          <%= for entry <- @uploads.csv_file.entries do %>
            <%= entry.progress %>%
          <% end %>
        </div>

        <div class="text-center">
          <div class="p-2">CSV file require headers</div>
          <div class="font-bold font-mono text-amber-600">
            <%= Enum.join(@seed_table_headers, ", ") %>
          </div>
        </div>

        <.button :if={@uploads.csv_file.errors == [] && @uploads.csv_file.entries != []}>
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
