defmodule FullCircleWeb.InvoiceLive.DetailComponent do
  use FullCircleWeb, :live_component
  alias FullCircle.Sys

  @impl true
  def mount(socket) do
    {:ok, socket}
  end

  @impl true
  def update(assigns, socket) do
    {:ok, socket |> assign(assigns)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id={@id} class={@klass}>
      <div class="font-medium flex flex-row text-center mt-2 tracking-tighter">
        <div class="detail-header detail-good-col"><%= gettext("Good") %></div>
        <div class="detail-header detail-desc-col">
          <%= gettext("Description") %>
        </div>
        <div class="detail-header detail-pack-col"><%= gettext("Package") %></div>
        <div class="detail-header detail-packqty-col"><%= gettext("Pack Qty") %></div>
        <div class="detail-header detail-qty-col"><%= gettext("Quantity") %></div>
        <div class="detail-header detail-unit-col"><%= gettext("Unit") %></div>
        <div class="detail-header detail-price-col"><%= gettext("Price") %></div>
        <div class={"detail-header detail-discount-col #{Sys.get_setting(@settings, @doc_name, "discount-col")}"}>
          <%= gettext("Discount") %>
        </div>
        <div class={"detail-header detail-goodamt-col #{Sys.get_setting(@settings, @doc_name, "goodamt-col")}"}>
          <%= gettext("Good Amt") %>
        </div>
        <div class={"detail-header detail-account-col #{Sys.get_setting(@settings, @doc_name, "account-col")}"}>
          <%= gettext("Account") %>
        </div>
        <div class="detail-header detail-taxcode-col"><%= gettext("TxCode") %></div>
        <div class={"detail-header detail-taxrate-col #{Sys.get_setting(@settings, @doc_name, "taxrate-col")}"}>
          <%= gettext("Tax%") %>
        </div>
        <div class={"detail-header detail-taxamt-col #{Sys.get_setting(@settings, @doc_name, "taxamt-col")}"}>
          <%= gettext("TaxAmt") %>
        </div>
        <div class="detail-header detail-amt-col"><%= gettext("Amount") %></div>
        <div class="detail-setting-col  mt-1 text-blue-500 grow-0 shrink-0">
          <.settings id="page-settings" settings={@settings} />
        </div>
      </div>

      <.inputs_for :let={dtl} field={@form[@detail_name]}>
        <div class={"flex flex-row #{if(dtl[:delete].value == true, do: "hidden", else: "")}"}>
          <div class="detail-good-col">
            <.input
              field={dtl[:good_name]}
              phx-hook="tributeAutoComplete"
              phx-debounce="500"
              url={"/api/companies/#{@current_company.id}/#{@current_user.id}/autocomplete?schema=good&name="}
            />
          </div>
          <%= Phoenix.HTML.Form.hidden_input(dtl, :good_id) %>
          <div class="detail-desc-col"><.input field={dtl[:descriptions]} /></div>
          <div class="detail-pack-col">
            <.input
              field={dtl[:package_name]}
              phx-hook="tributeAutoComplete"
              phx-debounce="500"
              url={"/api/companies/#{@current_company.id}/#{@current_user.id}/autocomplete?schema=packaging&good_id=#{dtl[:good_id].value}&name="}
            />
          </div>
          <%= Phoenix.HTML.Form.hidden_input(dtl, :unit_multiplier) %>
          <%= Phoenix.HTML.Form.hidden_input(dtl, :package_id) %>
          <div class="detail-packqty-col">
            <.input type="number" field={dtl[:package_qty]} />
          </div>
          <div class="detail-qty-col">
            <.input
              type="number"
              field={dtl[:quantity]}
              step="0.0001"
              phx-debounce="500"
              readonly={Phoenix.HTML.Form.input_value(dtl, :unit_multiplier) |> Decimal.gt?(0)}
            />
          </div>
          <div class="detail-unit-col">
            <.input field={dtl[:unit]} readonly tabindex="-1" />
          </div>
          <div class="detail-price-col">
            <.input type="number" phx-debounce="500" field={dtl[:unit_price]} step="0.0001" />
          </div>
          <div class={"detail-discount-col #{Sys.get_setting(@settings, @doc_name, "discount-col")}"}>
            <.input type="number" phx-debounce="500" field={dtl[:discount]} step="0.01" />
          </div>
          <div class={"detail-goodamt-col #{Sys.get_setting(@settings, @doc_name, "goodamt-col")}"}>
            <.input type="number" field={dtl[:good_amount]} readonly tabindex="-1" />
          </div>
          <div class={"detail-account-col #{Sys.get_setting(@settings, @doc_name, "account-col")}"}>
            <.input
              field={dtl[:account_name]}
              phx-hook="tributeAutoComplete"
              phx-debounce="500"
              url={"/api/companies/#{@current_company.id}/#{@current_user.id}/autocomplete?schema=account&name="}
            />
          </div>
          <%= Phoenix.HTML.Form.hidden_input(dtl, :account_id) %>
          <div class="detail-taxcode-col">
            <.input
              field={dtl[:tax_code_name]}
              phx-hook="tributeAutoComplete"
              phx-debounce="500"
              url={"/api/companies/#{@current_company.id}/#{@current_user.id}/autocomplete?schema=#{@taxcodetype}&name="}
            />
          </div>
          <%= Phoenix.HTML.Form.hidden_input(dtl, :tax_code_id) %>
          <div class={"detail-taxrate-col #{Sys.get_setting(@settings, @doc_name, "taxrate-col")}"}>
            <.input type="number" field={dtl[:tax_rate]} readonly step="0.0001" tabindex="-1" />
          </div>
          <div class={"detail-taxamt-col #{Sys.get_setting(@settings, @doc_name, "taxamt-col")}"}>
            <.input type="number" field={dtl[:tax_amount]} readonly tabindex="-1" />
          </div>
          <div class="detail-amt-col">
            <.input type="number" field={dtl[:amount]} readonly tabindex="-1" />
          </div>
          <div class="detail-setting-col mt-1 text-rose-500">
            <.link phx-click={:delete_detail} phx-value-index={dtl.index} tabindex="-1">
              <.icon name="hero-trash-solid" class="h-5 w-5" />
            </.link>
            <%= Phoenix.HTML.Form.hidden_input(dtl, :delete) %>
          </div>
        </div>
      </.inputs_for>

      <div class="flex flex-row font-medium tracking-tighter">
        <div class="mt-1 detail-good-col text-orange-500 text-center">
          <.link phx-click={:add_detail}>
            <.icon name="hero-plus-circle" class="w-5 h-5" /><%= gettext("Add Detail") %>
          </.link>
        </div>
        <div class="detail-desc-col" />
        <div class="detail-pack-col" />
        <div class="detail-packqty-col" />
        <div class="detail-qty-col" />
        <div class="detail-unit-col" />
        <div class="detail-price-col" />
        <div class={"detail-discount-col #{Sys.get_setting(@settings, @doc_name, "discount-col")}"} />
        <div class={"detail-goodamt-col #{Sys.get_setting(@settings, @doc_name, "goodamt-col")}"}>
          <.input
            type="number"
            field={@form[@doc_good_amount]}
            readonly
            tabindex="-1"
            value={Ecto.Changeset.fetch_field!(@form.source, @doc_good_amount)}
          />
        </div>
        <div class={"detail-account-col #{Sys.get_setting(@settings, @doc_name, "account-col")}"} />
        <div class="detail-taxcode-col" />
        <div class={"detail-taxrate-col #{Sys.get_setting(@settings, @doc_name, "taxrate-col")}"} />
        <div class={"detail-taxamt-col #{Sys.get_setting(@settings, @doc_name, "taxamt-col")}"}>
          <.input
            type="number"
            field={@form[@doc_tax_amount]}
            readonly
            tabindex="-1"
            value={Ecto.Changeset.fetch_field!(@form.source, @doc_tax_amount)}
          />
        </div>
        <div class="detail-amt-col">
          <.input
            feedback={true}
            type="number"
            field={@form[@doc_detail_amount]}
            readonly
            tabindex="-1"
            value={Ecto.Changeset.fetch_field!(@form.source, @doc_detail_amount)}
          />
        </div>
        <div class="detail-setting-col" />
      </div>
    </div>
    """
  end
end
