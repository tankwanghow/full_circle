defmodule FullCircleWeb.GoodLive.FormComponent do
  use FullCircleWeb, :live_component

  alias FullCircle.Product.{Good, Packaging}
  alias FullCircle.StdInterface

  @impl true
  def mount(socket) do
    {:ok,
     socket
     |> assign(
       account_names: [],
       tax_codes: []
     )}
  end

  @impl true
  def update(assigns, socket) do
    socket = socket |> assign(assigns)

    {:ok, socket}
  end

  @impl true
  def handle_event("cancel_delete", _, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_event("add_packaging", _, socket) do
    {:noreply, socket |> FullCircleWeb.Helpers.add_lines(:packagings, %Packaging{})}
  end

  @impl true
  def handle_event("delete_packaging", %{"index" => index}, socket) do
    {:noreply,
     socket |> FullCircleWeb.Helpers.delete_lines(String.to_integer(index), :packagings)}
  end

  @impl true
  def handle_event(
        "validate",
        %{"_target" => ["good", "purchase_account_name"], "good" => params},
        socket
      ) do
    fill_account_names(
      socket,
      params,
      "purchase_account_name",
      :account_names,
      "purchase_account_id"
    )
  end

  def handle_event(
        "validate",
        %{"_target" => ["good", "sales_account_name"], "good" => params},
        socket
      ) do
    fill_account_names(
      socket,
      params,
      "sales_account_name",
      :account_names,
      "sales_account_id"
    )
  end

  def handle_event(
        "validate",
        %{"_target" => ["good", "sales_tax_code_name"], "good" => params},
        socket
      ) do
    fill_tax_codes(
      socket,
      params,
      "sales_tax_code_name",
      :tax_codes,
      "sales_tax_code_id"
    )
  end

  def handle_event(
        "validate",
        %{"_target" => ["good", "purchase_tax_code_name"], "good" => params},
        socket
      ) do
    fill_tax_codes(
      socket,
      params,
      "purchase_tax_code_name",
      :tax_codes,
      "purchase_tax_code_id"
    )
  end

  def handle_event("validate", %{"good" => params}, socket) do
    validate(params, socket)
  end

  @impl true
  def handle_event("save", %{"good" => params}, socket) do
    save(socket, socket.assigns.live_action, params)
  end

  @impl true
  def handle_event("delete", _params, socket) do
    case StdInterface.delete(
           Good,
           "good",
           socket.assigns.form.data,
           socket.assigns.current_user,
           socket.assigns.current_company
         ) do
      {:ok, obj} ->
        send(self(), {:deleted, obj})
        {:noreply, socket}

      {:error, failed_operation, changeset, _} ->
        {:noreply,
         socket
         |> put_flash(
           :error,
           "#{gettext("Failed")} #{failed_operation}. #{list_errors_to_string(changeset.errors)}"
         )}

      :not_authorise ->
        send(self(), :not_authorise)
        {:noreply, socket}
    end
  end

  defp save(socket, :new, params) do
    case StdInterface.create(
           Good,
           "good",
           params,
           socket.assigns.current_user,
           socket.assigns.current_company
         ) do
      {:ok, obj} ->
        send(self(), {:created, obj})
        {:noreply, socket}

      {:error, failed_operation, changeset, _} ->
        {:noreply,
         socket
         |> assign(form: to_form(changeset))
         |> put_flash(
           :error,
           "#{gettext("Failed")} #{failed_operation}. #{list_errors_to_string(changeset.errors)}"
         )}

      :not_authorise ->
        send(self(), :not_authorise)
        {:noreply, socket}
    end
  end

  defp save(socket, :edit, params) do
    case StdInterface.update(
           Good,
           "good",
           socket.assigns.form.data,
           params,
           socket.assigns.current_user,
           socket.assigns.current_company
         ) do
      {:ok, obj} ->
        send(self(), {:updated, obj})
        {:noreply, socket}

      {:error, failed_operation, changeset, _} ->
        socket =
          socket
          |> assign(form: to_form(changeset))
          |> put_flash(
            :error,
            "#{gettext("Failed")} #{failed_operation}. #{list_errors_to_string(changeset.errors)}"
          )

        {:noreply, socket}

      :not_authorise ->
        send(self(), :not_authorise)
        {:noreply, socket}
    end
  end

  def fill_account_names(socket, params, terms_name, assign_names, assign_id) do
    socket =
      assign(
        socket,
        assign_names,
        FullCircle.Accounting.account_names(
          params[terms_name],
          socket.assigns.current_user,
          socket.assigns.current_company
        )
      )

    account =
      Enum.find(socket.assigns[assign_names], fn x ->
        x.value == params[terms_name]
      end)

    params = Map.merge(params, %{assign_id => Util.attempt(account, :id) || -1})
    validate(params, socket)
  end

  def fill_tax_codes(socket, params, terms_name, assign_names, assign_id) do
    socket =
      assign(
        socket,
        assign_names,
        FullCircle.Accounting.tax_codes(
          params[terms_name],
          socket.assigns.current_user,
          socket.assigns.current_company
        )
      )

    obj =
      Enum.find(socket.assigns[assign_names], fn x ->
        x.value == params[terms_name]
      end)

    params = Map.merge(params, %{assign_id => Util.attempt(obj, :id) || -1})

    validate(params, socket)
  end

  defp validate(params, socket) do
    changeset =
      StdInterface.changeset(
        Good,
        socket.assigns.form.data,
        params,
        socket.assigns.current_company
      )
      |> Map.put(:action, socket.assigns.live_action)

    socket = assign(socket, form: to_form(changeset))

    {:noreply, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div>
      <p class="w-full text-3xl text-center font-medium"><%= @title %></p>
      <.form
        for={@form}
        id="object-form"
        phx-target={@myself}
        autocomplete="off"
        phx-change="validate"
        phx-submit="save"
        class="mx-auto"
      >
        <div class="grid grid-cols-12 gap-2">
          <div class="col-span-9">
            <.input field={@form[:name]} label={gettext("Name")} />
          </div>
          <div class="col-span-3">
            <.input field={@form[:unit]} label={gettext("Unit")} />
          </div>
        </div>
        <div class="grid grid-cols-12 gap-2">
          <div class="col-span-9">
            <%= Phoenix.HTML.Form.hidden_input(@form, :sales_account_id) %>
            <.input
              field={@form[:sales_account_name]}
              label={gettext("Sales Account")}
              list="account_names"
              phx-debounce={500}
            />
          </div>
          <div class="col-span-3">
            <%= Phoenix.HTML.Form.hidden_input(@form, :sales_tax_code_id) %>
            <.input
              field={@form[:sales_tax_code_name]}
              label={gettext("Sales TaxCode")}
              list="tax_codes"
              phx-debounce={500}
            />
          </div>
        </div>

        <div class="grid grid-cols-12 gap-2">
          <div class="col-span-9">
            <%= Phoenix.HTML.Form.hidden_input(@form, :purchase_account_id) %>
            <.input
              field={@form[:purchase_account_name]}
              label={gettext("Purchase Account")}
              list="account_names"
              phx-debounce={500}
            />
          </div>
          <div class="col-span-3">
            <%= Phoenix.HTML.Form.hidden_input(@form, :purchase_tax_code_id) %>
            <.input
              field={@form[:purchase_tax_code_name]}
              label={gettext("Purchase TaxCode")}
              list="tax_codes"
              phx-debounce={500}
            />
          </div>
        </div>

        <div
          :if={Enum.count(Ecto.Changeset.get_field(@form.source, :packagings, [])) > 0}
          class="font-bold grid grid-cols-12 gap-2 mt-2"
        >
          <div class="col-span-4">
            <%= gettext("Package Name") %>
          </div>
          <div class="col-span-3">
            <%= gettext("Unit Multiplier") %>
          </div>
          <div class="col-span-4">
            <%= gettext("Cost Per Pack") %>
          </div>
        </div>
        <.inputs_for :let={pack} field={@form[:packagings]}>
          <div class={"grid grid-cols-12 gap-2 #{if(pack[:delete].value == true, do: "hidden", else: "")}"}>
            <div class="col-span-4">
              <.input field={pack[:name]} />
            </div>
            <div class="col-span-3">
              <.input type="number" field={pack[:unit_multiplier]} step="0.0001" />
            </div>
            <div class="col-span-4">
              <.input type="number" field={pack[:cost_per_package]} step="0.0001" />
            </div>
            <div class="col-span-1 mt-2.5 text-rose-500">
              <.link phx-click={:delete_packaging} phx-value-index={pack.index} phx-target={@myself}>
                <Heroicons.trash solid class="h-5 w-5" />
              </.link>
              <%= Phoenix.HTML.Form.hidden_input(pack, :delete) %>
            </div>
          </div>
        </.inputs_for>

        <div class="my-2">
          <.link phx-click={:add_packaging} phx-target={@myself} class={button_css()}>
            <%= gettext("Add Packaging") %>
          </.link>
        </div>

        <.input field={@form[:descriptions]} label={gettext("Descriptions")} type="textarea" />
        <%= datalist_with_ids(@account_names, "account_names") %>
        <%= datalist_with_ids(@tax_codes, "tax_codes") %>
        <div class="flex justify-center gap-x-1 mt-1">
          <.button disabled={!@form.source.valid?}><%= gettext("Save") %></.button>
          <%= if @live_action == :edit and FullCircle.Authorization.can?(@current_user, :delete_tax_code, @current_company) do %>
            <.delete_confirm_modal
              id="delete-object"
              msg1={gettext("All Good Transactions, will be LOST!!!")}
              msg2={gettext("Cannot Be Recover!!!")}
              confirm={JS.push("delete", target: "#object-form")}
              cancel={JS.push("cancel_delete", target: "#object-form")}
            />
          <% end %>
          <.link phx-click={JS.push("modal_cancel")} class={button_css()}>
            <%= gettext("Back") %>
          </.link>
        </div>
      </.form>
    </div>
    """
  end
end