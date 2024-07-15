defmodule FullCircleWeb.DeliveryLive.Form do
  use FullCircleWeb, :live_view

  alias FullCircle.Product
  alias FullCircle.Product.Delivery
  alias FullCircle.StdInterface

  @impl true
  def mount(params, _session, socket) do
    id = params["delivery_id"]
    ids = params["ids"]

    socket =
      case socket.assigns.live_action do
        :new -> mount_new(socket, ids)
        :edit -> mount_edit(socket, id)
      end

    {:ok, socket}
  end

  defp mount_new(socket, ids) do
    attrs =
      if !is_nil(ids) do
        ddd = Product.load_lines_to_delivery_lines(String.split(ids, ","))
        %{delivery_no: "...new...", delivery_details: ddd}
      else
        %{delivery_no: "...new..."}
      end

    socket
    |> assign(live_action: :new)
    |> assign(id: "new")
    |> assign(page_title: gettext("New Delivery"))
    |> assign(
      :form,
      to_form(
        StdInterface.changeset(
          Delivery,
          %Delivery{},
          attrs,
          socket.assigns.current_company
        )
      )
    )
  end

  defp mount_edit(socket, id) do
    object =
      Product.get_delivery!(
        id,
        socket.assigns.current_company,
        socket.assigns.current_user
      )

    socket
    |> assign(live_action: :edit)
    |> assign(id: id)
    |> assign(page_title: gettext("Edit Delivery") <> " " <> object.delivery_no)
    |> assign(
      :form,
      to_form(
        StdInterface.changeset(
          Delivery,
          object,
          %{},
          socket.assigns.current_company
        )
      )
    )
  end

  @impl true
  def handle_event("add_detail", _, socket) do
    cs =
      socket.assigns.form.source
      |> FullCircleWeb.Helpers.add_line(:delivery_details)
      |> Map.put(:action, socket.assigns.live_action)

    {:noreply, socket |> assign(form: to_form(cs))}
  end

  @impl true
  def handle_event("delete_detail", %{"index" => index}, socket) do
    cs =
      socket.assigns.form.source
      |> FullCircleWeb.Helpers.delete_line(index, :delivery_details)
      |> Map.put(:action, socket.assigns.live_action)

    {:noreply, socket |> assign(form: to_form(cs))}
  end

  @impl true
  def handle_event(
        "validate",
        %{"_target" => ["delivery", "customer_name"], "delivery" => params},
        socket
      ) do
    {params, socket, _} =
      FullCircleWeb.Helpers.assign_autocomplete_id(
        socket,
        params,
        "customer_name",
        "customer_id",
        &FullCircle.Accounting.get_contact_by_name/3
      )

    validate(params, socket)
  end

  @impl true
  def handle_event(
        "validate",
        %{
          "_target" => ["delivery", "delivery_details", id, "good_name"],
          "delivery" => params
        },
        socket
      ) do
    detail = params["delivery_details"][id]

    {detail, socket, good} =
      FullCircleWeb.Helpers.assign_autocomplete_id(
        socket,
        detail,
        "good_name",
        "good_id",
        &FullCircle.Product.get_good_by_name/3
      )

    detail =
      Map.merge(detail, %{
        "package_name" => Util.attempt(good, :package_name),
        "package_id" => Util.attempt(good, :package_id),
        "unit" => Util.attempt(good, :unit),
        "unit_multiplier" => Util.attempt(good, :unit_multiplier) || 0,
        "load_pack_qty" => 0
      })

    params =
      params
      |> FullCircleWeb.Helpers.merge_detail("delivery_details", id, detail)

    validate(params, socket)
  end

  @impl true
  def handle_event(
        "validate",
        %{
          "_target" => ["delivery", "delivery_details", id, "package_name"],
          "delivery" => params
        },
        socket
      ) do
    detail = params["delivery_details"][id]
    terms = detail["package_name"]

    pack =
      FullCircle.Product.get_packaging_by_name(
        String.trim(terms),
        detail["good_id"]
      )

    detail =
      Map.merge(detail, %{
        "package_id" => Util.attempt(pack, :id) || nil,
        "unit_multiplier" => Util.attempt(pack, :unit_multiplier) || 0
      })

    params =
      params
      |> FullCircleWeb.Helpers.merge_detail("delivery_details", id, detail)

    validate(params, socket)
  end

  def handle_event("validate", %{"delivery" => params}, socket) do
    validate(params, socket)
  end

  @impl true
  def handle_event("save", %{"delivery" => params}, socket) do
    save(socket, socket.assigns.live_action, params)
  end

  @impl true
  def handle_params(_params, uri, socket) do
    {:noreply, socket |> assign(cancel_url: uri)}
  end

  defp save(socket, :new, params) do
    case Product.create_delivery(
           params,
           socket.assigns.current_company,
           socket.assigns.current_user
         ) do
      {:ok, %{create_delivery: obj}} ->
        {:noreply,
         socket
         |> push_navigate(
           to: ~p"/companies/#{socket.assigns.current_company.id}/Delivery/#{obj.id}/edit"
         )
         |> put_flash(:info, "#{gettext("Delivery created successfully.")}")}

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

  defp save(socket, :edit, params) do
    case Product.update_delivery(
           socket.assigns.form.data,
           params,
           socket.assigns.current_company,
           socket.assigns.current_user
         ) do
      {:ok, %{update_delivery: obj}} ->
        {:noreply,
         socket
         |> push_navigate(
           to: ~p"/companies/#{socket.assigns.current_company.id}/Delivery/#{obj.id}/edit"
         )
         |> put_flash(:info, "#{gettext("Delivery updated successfully.")}")}

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

  defp validate(params, socket) do
    changeset =
      StdInterface.changeset(
        Delivery,
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
    <div class="w-8/12 mx-auto bload rounded-lg bload-yellow-500 bg-yellow-100 p-4">
      <p class="w-full text-3xl text-center font-medium"><%= @page_title %></p>
      <.form for={@form} id="object-form" autocomplete="off" phx-change="validate" phx-submit="save">
        <.input type="hidden" field={@form[:delivery_no]} />
        <div class="flex flex-row flex-nowarp gap-2">
          <div class="w-1/2 grow shrink">
            <.input type="hidden" field={@form[:customer_id]} />
            <.input
              field={@form[:customer_name]}
              label={gettext("Customer")}
              phx-hook="tributeAutoComplete"
              url={"/list/companies/#{@current_company.id}/#{@current_user.id}/autocomplete?schema=contact&name="}
            />
          </div>
          <div class="grow shrink w-1/4">
            <.input field={@form[:delivery_date]} label={gettext("Delivery Date")} type="date" />
          </div>
          <div class="grow shrink w-1/4">
            <.input field={@form[:lorry]} label={gettext("Lorry")} />
          </div>
        </div>

        <.live_component
          module={FullCircleWeb.DeliveryLive.DetailComponent}
          id="delivery_details"
          klass=""
          doc_name="Delivery"
          detail_name={:delivery_details}
          form={@form}
          current_company={@current_company}
          current_user={@current_user}
        />

        <div class="flex flex-row flex-nowrap gap-2">
          <div class="w-[50%]">
            <.input field={@form[:descriptions]} label={gettext("Descriptions")} />
          </div>
          <div class="w-[30%]">
            <.input
              field={@form[:loader_tags]}
              label={gettext("Delivery Man Tags")}
              phx-hook="tributeTagText"
              url={"/list/companies/#{@current_company.id}/#{@current_user.id}/tags?klass=FullCircle.Product.Delivery&tag_field=delivery_man_tags&tag="}
            />
          </div>
          <div class="w-[20%]">
            <.input
              field={@form[:loader_wages_tags]}
              label={gettext("Delivery Wages Tags")}
              phx-hook="tributeTagText"
              url={"/list/companies/#{@current_company.id}/#{@current_user.id}/tags?klass=FullCircle.Product.Deliveryer&tag_field=delivery_wages_tags&tag="}
            />
          </div>
        </div>

        <div class="flex flex-row justify-center gap-x-1 mt-1">
          <.form_action_button
            form={@form}
            live_action={@live_action}
            current_company={@current_company}
            type="Delivery"
          />
          <.print_button
            :if={@live_action == :edit}
            company={@current_company}
            doc_type="Delivery"
            doc_id={@id}
            class="gray button"
          />
          <.pre_print_button
            :if={@live_action == :edit}
            company={@current_company}
            doc_type="Delivery"
            doc_id={@id}
            class="gray button"
          />
          <.live_component
            :if={@live_action == :edit}
            module={FullCircleWeb.LogLive.Component}
            id={"log_#{@id}"}
            show_log={false}
            entity="loads"
            entity_id={@id}
          />
        </div>
      </.form>
    </div>
    """
  end
end
