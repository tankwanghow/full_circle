defmodule FullCircleWeb.LayerLive.FlockForm do
  use FullCircleWeb, :live_view
  alias FullCircle.StdInterface
  alias FullCircle.Layer.Flock

  @impl true
  def mount(params, _session, socket) do
    id = params["flock_id"]

    socket =
      case socket.assigns.live_action do
        :new -> mount_new(socket)
        :edit -> mount_edit(socket, id)
      end

    {:ok, socket}
  end

  defp mount_new(socket) do
    socket
    |> assign(live_action: :new)
    |> assign(id: "new")
    |> assign(page_title: gettext("New Flock"))
    |> assign(
      :form,
      to_form(StdInterface.changeset(Flock, %Flock{}, %{}, socket.assigns.current_company))
    )
  end

  defp mount_edit(socket, id) do
    obj = FullCircle.Layer.get_flock!(id, socket.assigns.current_company)

    socket
    |> assign(live_action: :edit)
    |> assign(id: id)
    |> assign(page_title: gettext("Edit Flock"))
    |> assign(
      :form,
      to_form(StdInterface.changeset(Flock, obj, %{}, socket.assigns.current_company))
    )
  end

  @impl true
  def handle_event("add_movement", _, socket) do
    cs =
      socket.assigns.form.source
      |> FullCircleWeb.Helpers.add_line(:movements)
      |> Map.put(:action, socket.assigns.live_action)

    {:noreply, socket |> assign(form: to_form(cs))}
  end

  @impl true
  def handle_event("delete_movement", %{"index" => index}, socket) do
    cs =
      socket.assigns.form.source
      |> FullCircleWeb.Helpers.delete_line(index, :movements)
      |> Map.put(:action, socket.assigns.live_action)

    {:noreply, socket |> assign(form: to_form(cs))}
  end

  @impl true
  def handle_event(
        "validate",
        %{"_target" => ["flock", "movements", id, "house_no"], "flock" => params},
        socket
      ) do
    detail = params["movements"][id]

    dt =
      if(detail["move_date"] != "",
        do: detail["move_date"] |> Timex.parse!("{YYYY}-{0M}-{0D}") |> NaiveDateTime.to_date(),
        else: Timex.today()
      )

    h_no = detail["house_no"] |> String.trim()

    info = FullCircle.Layer.get_house_info_at(dt, h_no, socket.assigns.current_company.id)

    info_str =
      cond do
        is_nil(info) ->
          nil

        info.qty > 0 ->
          "At #{dt} House #{info.house_no} has Flock No #{info.flock_no} with quantity #{Integer.to_string(info.qty)}."

        info.qty <= 0 ->
          "At #{dt} House #{info.house_no} is empty."
      end

    detail =
      Map.merge(detail, %{
        "house_id" => Util.attempt(info, :id),
        "house_info" => info_str,
        "company_id" => socket.assigns.current_company.id
      })

    params =
      params
      |> FullCircleWeb.Helpers.merge_detail("movements", id, detail)

    validate(params, socket)
  end

  @impl true
  def handle_event("validate", %{"flock" => params}, socket) do
    validate(params, socket)
  end

  @impl true
  def handle_event("save", %{"flock" => params}, socket) do
    save(socket, socket.assigns.live_action, params)
  end

  @impl true
  def handle_event("delete", _params, socket) do
    case StdInterface.delete(
           Flock,
           "flock",
           socket.assigns.form.data,
           socket.assigns.current_company,
           socket.assigns.current_user
         ) do
      {:ok, _ac} ->
        {:noreply,
         socket
         |> push_navigate(to: "/companies/#{socket.assigns.current_company.id}/flocks")
         |> put_flash(:info, "#{gettext("Flock deleted successfully.")}")}

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

  defp save(socket, :new, params) do
    case StdInterface.create(
           Flock,
           "flock",
           params,
           socket.assigns.current_company,
           socket.assigns.current_user
         ) do
      {:ok, ac} ->
        {:noreply,
         socket
         |> push_navigate(
           to: ~p"/companies/#{socket.assigns.current_company.id}/flocks/#{ac.id}/edit"
         )
         |> put_flash(:info, "#{gettext("Flock created successfully.")}")}

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
    case StdInterface.update(
           Flock,
           "flock",
           socket.assigns.form.data,
           params,
           socket.assigns.current_company,
           socket.assigns.current_user
         ) do
      {:ok, ac} ->
        {:noreply,
         socket
         |> push_navigate(
           to: ~p"/companies/#{socket.assigns.current_company.id}/flocks/#{ac.id}/edit"
         )
         |> put_flash(:info, "#{gettext("Flock updated successfully.")}")}

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

  defp validate(params, socket) do
    changeset =
      StdInterface.changeset(
        Flock,
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
    <div class="w-6/12 mx-auto border rounded-lg border-yellow-500 bg-yellow-100 p-4">
      <p class="w-full text-3xl text-center font-medium"><%= @page_title %></p>
      <.form
        for={@form}
        id="object-form"
        autocomplete="off"
        phx-change="validate"
        phx-submit="save"
        class="mx-auto"
      >
        <div class="grid grid-cols-12 gap-1">
          <div class="col-span-3">
            <.input field={@form[:dob]} label={gettext("DOB")} type="date" />
          </div>
          <div class="col-span-3">
            <.input field={@form[:flock_no]} label={gettext("Flock No")} />
          </div>
          <div class="col-span-3">
            <.input field={@form[:quantity]} label={gettext("Quantity")} type="number" />
          </div>
          <div class="col-span-3">
            <.input field={@form[:breed]} label={gettext("Breed")} />
          </div>
          <div class="col-span-12">
            <.input field={@form[:Note]} label={gettext("Note")} />
          </div>
        </div>

        <div class="font-bold flex flex-row text-center mt-2">
          <div class="w-[20%]"><%= gettext("Move Date") %></div>
          <div class="w-[20%]"><%= gettext("House") %></div>
          <div class="w-[20%]"><%= gettext("Quantity") %></div>
          <div class="w-[37%]"><%= gettext("Note") %></div>
          <div class="w-[3%]" />
        </div>
        <.inputs_for :let={move} field={@form[:movements]}>
          <div class={"flex flex-row  #{if(move[:delete].value == true and Enum.count(move.errors) == 0, do: "hidden", else: "")}"}>
            <div class="w-[20%]">
              <.input type="date" field={move[:move_date]} />
            </div>
            <div class="w-[20%]">
              <%= Phoenix.HTML.Form.hidden_input(move, :house_id) %>
              <%= Phoenix.HTML.Form.hidden_input(move, :company_id) %>
              <.input
                field={move[:house_no]}
                phx-hook="tributeAutoComplete"
                url={"/api/companies/#{@current_company.id}/#{@current_user.id}/autocomplete?schema=house&name="}
              />
            </div>

            <div class="w-[20%]">
              <.input type="number" field={move[:quantity]} />
            </div>
            <div class="w-[37%]">
              <.input field={move[:note]} />
            </div>
            <div class="w-[3%] mt-1.5 text-rose-500">
              <.link phx-click={:delete_movement} phx-value-index={move.index}>
                <Heroicons.trash solid class="h-5 w-5" />
              </.link>
              <%= Phoenix.HTML.Form.hidden_input(move, :delete) %>
            </div>
          </div>
          <span class="text-sm text-gray-500">
            <%= Phoenix.HTML.Form.input_value(move, :house_info) %>
          </span>
        </.inputs_for>

        <div class="my-2">
          <.link phx-click={:add_movement} class="text-orange-500 hover:font-bold focus:font-bold">
            <.icon name="hero-plus-circle" class="w-5 h-5" /><%= gettext("Add Movement") %>
          </.link>
        </div>

        <div class="flex justify-center gap-x-1 mt-1">
          <.form_action_button
            form={@form}
            live_action={@live_action}
            current_company={@current_company}
            type="flocks"
          />
          <%= if @live_action == :edit and FullCircle.Authorization.can?(@current_user, :delete_flock, @current_company) do %>
            <.delete_confirm_modal
              id="delete-object"
              msg1={gettext("All Flock Transactions, will be LOST!!!")}
              msg2={gettext("Cannot Be Recover!!!")}
              confirm={
                JS.push("delete", target: "#object-form")
                |> JS.hide(to: "#delete-object-modal")
              }
            />
          <% end %>
          <.live_component
            :if={@live_action == :edit}
            module={FullCircleWeb.LogLive.Component}
            id={"log_#{@id}"}
            show_log={false}
            entity="flocks"
            entity_id={@id}
          />
        </div>
      </.form>
    </div>
    """
  end
end
