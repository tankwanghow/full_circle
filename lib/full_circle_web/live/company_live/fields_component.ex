defmodule FullCircleWeb.CompanyLive.FieldsComponent do
  use FullCircleWeb, :live_component

  @impl true
  def render(assigns) do
    ~H"""
    <div class="grid grid-cols-12 gap-2">
      <div class="col-span-12">
        <.input field={@form[:name]} label={gettext("Name")} />
      </div>
      <div class="col-span-6">
        <.input field={@form[:address1]} label={gettext("Address Line 1")} />
      </div>
      <div class="col-span-6">
        <.input field={@form[:address2]} label={gettext("Address Line 2")} />
      </div>
      <div class="col-span-4">
        <.input field={@form[:city]} label={gettext("City")} />
      </div>
      <div class="col-span-4">
        <.input field={@form[:zipcode]} label={gettext("Postal Code")} />
      </div>
      <div class="col-span-4">
        <.input field={@form[:state]} label={gettext("State")} />
      </div>
      <div class="col-span-4">
        <.input field={@form[:country]} label={gettext("Country")} list="countries" />
      </div>
      <div class="col-span-4">
        <.input field={@form[:timezone]} label={gettext("Time Zone")} list="timezones" />
      </div>
      <div class="col-span-4">
        <.input field={@form[:tel]} label={gettext("Tel")} />
      </div>
      <div class="col-span-4">
        <.input field={@form[:fax]} label={gettext("Fax")} />
      </div>
      <div class="col-span-4">
        <.input field={@form[:email]} type="email" label={gettext("Email")} />
      </div>
      <div class="col-span-4">
        <.input field={@form[:reg_no]} label={gettext("Reg No")} />
      </div>
      <div class="col-span-4">
        <.input field={@form[:tax_id]} label={gettext("Tax No")} />
      </div>
      <div class="col-span-4">
        <.input

          field={@form[:closing_month]}
          options={[
            January: 1,
            February: 2,
            March: 3,
            April: 4,
            May: 5,
            June: 6,
            July: 7,
            August: 8,
            September: 9,
            October: 10,
            November: 11,
            December: 12
          ]}
          type="select"
          label={gettext("Closing Month")}
        />
      </div>
      <div class="col-span-4">
        <.input
          field={@form[:closing_day]}
          options={Enum.to_list(1..31)}
          type="select"
          label={gettext("Closing Day")}
        />
      </div>
      <div class="col-span-12">
        <.input field={@form[:descriptions]} label={gettext("Descriptions")} />
      </div>
    </div>
    <%= datalist(FullCircle.Sys.countries(), "countries") %>
    <%= datalist(Tzdata.zone_list(), "timezones") %>
    """
  end
end
