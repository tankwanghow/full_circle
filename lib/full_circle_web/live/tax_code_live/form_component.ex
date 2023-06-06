defmodule FullCircleWeb.TaxCodeLive.FormComponent do
  use FullCircleWeb, :live_component

  alias FullCircle.Accounting.TaxCode
  alias FullCircle.StdInterface

  @impl true
  def mount(socket) do
    {:ok, socket |> assign(:account_names, [])}
  end

  @impl true
  def update(assigns, socket) do
    socket = socket |> assign(assigns)

    {:ok, socket}
  end

  @impl true
  def handle_event(
        "validate",
        %{"_target" => ["tax_code", "account_name"], "tax_code" => params},
        socket
      ) do
    {params, socket, _} =
      FullCircleWeb.Helpers.assign_list_n_id(
        socket,
        params,
        "account_name",
        :account_names,
        "account_id",
        &FullCircle.Accounting.account_names/3
      )

    validate(params, socket)
  end

  @impl true
  def handle_event("validate", %{"tax_code" => params}, socket) do
    validate(params, socket)
  end

  @impl true
  def handle_event("save", %{"tax_code" => params}, socket) do
    save(socket, socket.assigns.live_action, params)
  end

  @impl true
  def handle_event("delete", _params, socket) do
    case StdInterface.delete(
           TaxCode,
           "tax_code",
           socket.assigns.form.data,
           socket.assigns.current_company,
           socket.assigns.current_user
         ) do
      {:ok, obj} ->
        send(self(), {:deleted, obj})
        {:noreply, socket}

      {:error, _, changeset, _} ->
        {:noreply, assign(socket, form: to_form(changeset))}

      :not_authorise ->
        send(self(), :not_authorise)
        {:noreply, socket}
    end
  end

  defp save(socket, :new, params) do
    case StdInterface.create(
           TaxCode,
           "tax_code",
           params,
           socket.assigns.current_company,
           socket.assigns.current_user
         ) do
      {:ok, obj} ->
        send(self(), {:created, obj})
        {:noreply, socket}

      {:error, _, changeset, _} ->
        {:noreply, assign(socket, form: to_form(changeset))}

      :not_authorise ->
        send(self(), :not_authorise)
        {:noreply, socket}
    end
  end

  defp save(socket, :edit, params) do
    case StdInterface.update(
           TaxCode,
           "tax_code",
           socket.assigns.form.data,
           params,
           socket.assigns.current_company,
           socket.assigns.current_user
         ) do
      {:ok, obj} ->
        send(self(), {:updated, obj})
        {:noreply, socket}

      {:error, _, changeset, _} ->
        {:noreply, assign(socket, form: to_form(changeset))}

      :not_authorise ->
        send(self(), :not_authorise)
        {:noreply, socket}
    end
  end

  defp validate(params, socket) do
    changeset =
      StdInterface.changeset(
        TaxCode,
        socket.assigns.form.data,
        params,
        socket.assigns.current_company
      )
      |> Map.put(:action, :insert)

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
        class="max-w-md mx-auto"
      >
        <.input field={@form[:code]} label={gettext("Code")} />

        <.input
          field={@form[:tax_type]}
          label={gettext("TaxCode Type")}
          type="select"
          options={FullCircle.Accounting.tax_types()}
        />
        <.input
          field={@form[:rate]}
          type="number"
          step="0.0001"
          label={gettext("Rate (example:- 6% = 0.06, 10% = 0.1)")}
        />
        <%= Phoenix.HTML.Form.hidden_input(@form, :account_id) %>
        <.input
          field={@form[:account_name]}
          label={gettext("Account")}
          list="account_names"
          phx-debounce={500}
        />
        <.input field={@form[:descriptions]} label={gettext("Descriptions")} type="textarea" />

        <div class="flex justify-center gap-x-1 mt-1">
          <.button disabled={!@form.source.valid?}><%= gettext("Save") %></.button>
          <%= if @live_action == :edit and FullCircle.Authorization.can?(@current_user, :delete_tax_code, @current_company) do %>
            <.delete_confirm_modal
              id="delete-object"
              msg1={gettext("All TaxCode Transactions, will be LOST!!!")}
              msg2={gettext("Cannot Be Recover!!!")}
              confirm={
                JS.remove_attribute("class", to: "#phx-feedback-for-tax_code_code")
                |> JS.push("delete", target: "#object-form")
                |> JS.hide(to: "#delete-object-modal")
              }
            />
          <% end %>
          <.link phx-click={JS.exec("phx-remove", to: "#object-crud-modal")} class={button_css()}>
            <%= gettext("Back") %>
          </.link>
        </div>
      </.form>
      <%= datalist_with_ids(@account_names, "account_names") %>
    </div>
    """
  end
end
