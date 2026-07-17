defmodule FullCircleWeb.TradingLocationLive.Form do
  use FullCircleWeb, :live_view

  alias FullCircle.Trading
  alias FullCircle.Trading.Location
  alias FullCircle.Authorization

  @impl true
  def mount(params, _session, socket) do
    company = socket.assigns.current_company
    user = socket.assigns.current_user

    cond do
      not Authorization.can?(user, :manage_trading, company) ->
        {:ok,
         socket
         |> put_flash(:error, gettext("You are not authorised to perform this action"))
         |> push_navigate(to: ~p"/companies/#{company.id}/dashboard")}

      socket.assigns.live_action == :new ->
        cs = Location.changeset(%Location{}, %{"company_id" => company.id, "active" => true})

        {:ok,
         socket
         |> assign(page_title: gettext("New Location"))
         |> assign(live_action: :new)
         |> assign(form: to_form(cs))}

      true ->
        loc = Trading.get_location!(params["id"], company, user)
        cs = Location.changeset(loc, %{})

        {:ok,
         socket
         |> assign(page_title: gettext("Edit Location"))
         |> assign(live_action: :edit)
         |> assign(location: loc)
         |> assign(form: to_form(cs))}
    end
  end

  @impl true
  def handle_event("validate", %{"location" => params}, socket) do
    validate(params, socket)
  end

  def handle_event("map_pick", %{"latitude" => lat, "longitude" => lng}, socket) do
    params =
      socket.assigns.form.params
      |> Map.put("company_id", socket.assigns.current_company.id)
      |> Map.put("latitude", blank_to_nil(lat))
      |> Map.put("longitude", blank_to_nil(lng))

    # Prefer current form params so other fields are not wiped when map is clicked
    params = merge_form_params(socket, params)
    validate(params, socket)
  end

  def handle_event("save", %{"location" => params}, socket) do
    company = socket.assigns.current_company
    user = socket.assigns.current_user

    result =
      case socket.assigns.live_action do
        :new -> Trading.create_location(params, company, user)
        :edit -> Trading.update_location(socket.assigns.location, params, company, user)
      end

    case result do
      {:ok, _loc} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Location saved successfully."))
         |> push_navigate(to: ~p"/companies/#{company.id}/trading/locations")}

      {:error, %Ecto.Changeset{} = cs} ->
        {:noreply, assign(socket, form: to_form(cs))}

      :not_authorise ->
        {:noreply,
         put_flash(socket, :error, gettext("You are not authorised to perform this action"))}
    end
  end

  defp validate(params, socket) do
    params = Map.put(params, "company_id", socket.assigns.current_company.id)

    cs =
      case socket.assigns.live_action do
        :new -> Location.changeset(%Location{}, params)
        :edit -> Location.changeset(socket.assigns.location, params)
      end
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, form: to_form(cs))}
  end

  defp merge_form_params(socket, pick) do
    base =
      case socket.assigns.form do
        %{params: params} when is_map(params) and map_size(params) > 0 ->
          params

        %{source: %Ecto.Changeset{} = cs} ->
          cs
          |> Ecto.Changeset.apply_changes()
          |> Map.from_struct()
          |> Map.drop([:__meta__, :company, :contact])
          |> Map.new(fn {k, v} -> {to_string(k), v} end)

        _ ->
          %{}
      end

    Map.merge(base, pick)
  end

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(v), do: v

  @impl true
  def render(assigns) do
    ~H"""
    <div class="mx-auto w-7/12">
      <p class="w-full text-3xl text-center font-medium">{@page_title}</p>
      <.form
        for={@form}
        id="location-form"
        phx-change="validate"
        phx-submit="save"
        autocomplete="off"
        class="p-4 border rounded space-y-2"
      >
        <div class="flex gap-2">
          <div class="w-3/4">
            <.input field={@form[:name]} label={gettext("Name")} />
          </div>
          <div class="w-1/4">
            <.input
              field={@form[:kind]}
              type="select"
              label={gettext("Kind")}
              options={Enum.map(Location.kinds(), &{&1, &1})}
            />
          </div>
        </div>

        <.input field={@form[:address_note]} type="textarea" label={gettext("Address note")} />

        <div class="space-y-1">
          <label class="block text-sm font-semibold leading-6 text-zinc-800 dark:text-zinc-200">
            {gettext("GPS location")}
          </label>
          <p class="text-xs text-gray-500">
            {gettext(
              "Search a city/town to zoom the map, then click to drop a pin (or drag / use my location)."
            )}
          </p>

          <div
            id="gps-map-picker"
            phx-hook="GpsMapPicker"
            phx-update="ignore"
            data-lat-input="location_latitude"
            data-lng-input="location_longitude"
            data-lat={@form[:latitude].value}
            data-lng={@form[:longitude].value}
            class="border rounded overflow-hidden bg-zinc-50 dark:bg-zinc-900"
          >
            <div class="relative p-2 border-b bg-white dark:bg-zinc-800">
              <div class="flex gap-1">
                <input
                  type="search"
                  data-gps-search
                  autocomplete="off"
                  placeholder={gettext("Search city or town… e.g. Kajang, Port Klang")}
                  class="flex-1 rounded border border-zinc-300 dark:border-zinc-600 bg-white dark:bg-zinc-900 px-3 py-1.5 text-sm"
                />
                <button type="button" data-gps-search-btn class="blue button text-sm shrink-0">
                  {gettext("Search")}
                </button>
              </div>
              <div
                data-gps-search-results
                class="hidden absolute left-2 right-2 z-[1000] mt-1 max-h-56 overflow-y-auto rounded border border-zinc-300 dark:border-zinc-600 bg-white dark:bg-zinc-800 shadow-lg"
              >
              </div>
            </div>
            <div data-gps-map class="w-full h-72 z-0"></div>
            <div class="flex flex-wrap gap-2 p-2 items-center border-t bg-white dark:bg-zinc-800">
              <button type="button" data-gps-locate class="blue button text-sm">
                {gettext("Use my location")}
              </button>
              <button type="button" data-gps-clear class="gray button text-sm">
                {gettext("Clear GPS")}
              </button>
              <a
                :if={maps_url(@form)}
                href={maps_url(@form)}
                target="_blank"
                rel="noopener noreferrer"
                class="teal button text-sm"
              >
                {gettext("Open in Google Maps")}
              </a>
              <span data-gps-status class="text-xs text-gray-600 font-mono ml-auto">
                {gps_label(@form)}
              </span>
            </div>
          </div>

          <div class="flex gap-2">
            <.input
              field={@form[:latitude]}
              type="number"
              step="any"
              label={gettext("Latitude")}
              placeholder="e.g. 3.1390"
            />
            <.input
              field={@form[:longitude]}
              type="number"
              step="any"
              label={gettext("Longitude")}
              placeholder="e.g. 101.6869"
            />
          </div>
        </div>

        <.input field={@form[:active]} type="checkbox" label={gettext("Active")} />
        <div class="text-center mt-4">
          <.button>{gettext("Save")}</.button>
          <.link
            navigate={~p"/companies/#{@current_company.id}/trading/locations"}
            class="gray button"
          >
            {gettext("Back")}
          </.link>
        </div>
      </.form>
    </div>
    """
  end

  defp maps_url(form) do
    Location.google_maps_url(form[:latitude].value, form[:longitude].value)
  end

  defp gps_label(form) do
    Location.gps_label(form[:latitude].value, form[:longitude].value)
  end
end
