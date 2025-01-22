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
        <div class="detail-header detail-good-col">{gettext("Good")}</div>
        <div class="detail-header detail-desc-col">
          {gettext("Description")}
        </div>
        <div class="detail-header detail-pack-col">{gettext("Package")}</div>
        <div class="detail-header detail-packqty-col">{gettext("Pack Qty")}</div>
        <div class="detail-header detail-qty-col">{gettext("Quantity")}</div>
        <div class="detail-header detail-unit-col">{gettext("Unit")}</div>
        <div class="detail-header detail-price-col">{gettext("Price")}</div>
        <div class={"detail-header detail-discount-col #{Sys.get_setting(@settings, @doc_name, "discount-col")}"}>
          {gettext("Discount")}
        </div>
        <div class={"detail-header detail-goodamt-col #{Sys.get_setting(@settings, @doc_name, "goodamt-col")}"}>
          {gettext("Good Amt")}
        </div>
        <div class={"detail-header detail-account-col #{Sys.get_setting(@settings, @doc_name, "account-col")}"}>
          {gettext("Account")}
        </div>
        <div class="detail-header detail-taxcode-col">{gettext("TxCode")}</div>
        <div class={"detail-header detail-taxrate-col #{Sys.get_setting(@settings, @doc_name, "taxrate-col")}"}>
          {gettext("Tax%")}
        </div>
        <div class={"detail-header detail-taxamt-col #{Sys.get_setting(@settings, @doc_name, "taxamt-col")}"}>
          {gettext("TaxAmt")}
        </div>
        <div class="detail-header detail-amt-col">{gettext("Amount")}</div>
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
              url={"/list/companies/#{@current_company.id}/#{@current_user.id}/autocomplete?schema=good&name="}
            />
          </div>
          <.input type="hidden" field={dtl[:good_id]} />
          <div class="detail-desc-col"><.input field={dtl[:descriptions]} /></div>
          <div class="detail-pack-col">
            <.input
              field={dtl[:package_name]}
              phx-hook="tributeAutoComplete"
              url={"/list/companies/#{@current_company.id}/#{@current_user.id}/autocomplete?schema=packaging&good_id=#{dtl[:good_id].value}&name="}
            />
          </div>
          <.input type="hidden" field={dtl[:unit_multiplier]} />
          <.input type="hidden" field={dtl[:package_id]} />
          <div class="detail-packqty-col">
            <.input phx-hook="calculatorInput" klass="text-right" field={dtl[:package_qty]} />
          </div>
          <div class="detail-qty-col">
            <.input
              phx-hook="calculatorInput"
              klass="text-right"
              field={dtl[:quantity]}
              step="0.0001"
              disabled={Phoenix.HTML.Form.input_value(dtl, :unit_multiplier) |> Decimal.gt?(0)}
            />
          </div>
          <div class="detail-unit-col">
            <.input field={dtl[:unit]} readonly tabindex="-1" />
          </div>
          <div class="detail-price-col">
            <.input
              field={dtl[:unit_price]}
              step="0.0001"
              phx-hook="calculatorInput"
              klass="text-right"
            />
          </div>
          <div class={"detail-discount-col #{Sys.get_setting(@settings, @doc_name, "discount-col")}"}>
            <.input field={dtl[:discount]} phx-hook="calculatorInput" klass="text-right" />
          </div>
          <div class={"detail-goodamt-col #{Sys.get_setting(@settings, @doc_name, "goodamt-col")}"}>
            <.input type="number" field={dtl[:good_amount]} readonly tabindex="-1" />
          </div>
          <div class={"detail-account-col #{Sys.get_setting(@settings, @doc_name, "account-col")}"}>
            <.input
              field={dtl[:account_name]}
              phx-hook="tributeAutoComplete"
              url={"/list/companies/#{@current_company.id}/#{@current_user.id}/autocomplete?schema=account&name="}
            />
          </div>
          <.input type="hidden" field={dtl[:account_id]} />
          <div class="detail-taxcode-col">
            <.input
              field={dtl[:tax_code_name]}
              phx-hook="tributeAutoComplete"
              url={"/list/companies/#{@current_company.id}/#{@current_user.id}/autocomplete?schema=#{@taxcodetype}&name="}
            />
          </div>
          <.input type="hidden" field={dtl[:tax_code_id]} />
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
            <.input type="hidden" field={dtl[:delete]} value={"#{dtl[:delete].value}"} />
          </div>
        </div>
      </.inputs_for>

      <div class="flex flex-row">
        <div class="mt-1 detail-good-col text-orange-500 text-left">
          <.link phx-click={:add_detail} class="hover:font-bold focus:font-bold">
            <.icon name="hero-plus-circle" class="w-5 h-5" />{gettext("Add Detail")}
          </.link>
        </div>
        <div class="w-[10%] text-right px-1 pt-1">
          {gettext("Good Total")}
        </div>
        <div class="detail-amt-col text-right px-1 pt-1">
          {Ecto.Changeset.fetch_field!(@form.source, @doc_good_amount)
          |> Number.Delimit.number_to_delimited()}
        </div>
        <div class="detail-setting-col" />
      </div>

      <div class="flex flex-row">
        <div class="w-[82%]"></div>
        <div class="w-[10%] text-right px-1">
          {gettext("Tax Total")}
        </div>
        <div class="detail-amt-col text-right px-1">
          {Ecto.Changeset.fetch_field!(@form.source, @doc_tax_amount)
          |> Number.Delimit.number_to_delimited()}
        </div>
        <div class="detail-setting-col" />
      </div>

      <div class="flex flex-row">
        <div class="w-[82%]"></div>
        <div class={"w-[10%] text-right px-1 border-t #{if(@matched_trans == [], do: "font-semibold border-b-4 border-double")} border-black"}>
          {gettext("Invoice Total")}
        </div>
        <div class={"detail-amt-col text-right border-t #{if(@matched_trans == [], do: "font-semibold border-b-4 border-double")} border-black"}>
          <div>
            {Ecto.Changeset.fetch_field!(@form.source, @doc_detail_amount)
            |> Number.Delimit.number_to_delimited()}
          </div>
          <.error :for={msg <- Enum.map(@form[@doc_detail_amount].errors, &translate_error(&1))}>
            {msg}
          </.error>
        </div>
        <div class="detail-setting-col" />
      </div>

      <%= for obj <- @matched_trans do %>
        <div class="flex flex-row">
          <div class="w-[82%]"></div>
          <div class="w-[10%] text-right px-1">
            <.link
              class="text-red-600 hover:font-bold"
              target="_blank"
              navigate={"/companies/#{@current_company.id}/#{obj.doc_type}/#{obj.doc_id}/edit"}
            >
              {gettext("Less")} {obj.doc_type}
            </.link>
          </div>
          <div class="text-red-600 detail-amt-col text-right px-1">
            {Number.Delimit.number_to_delimited(obj.match_amount |> Decimal.abs())}
          </div>
          <div class="detail-setting-col" />
        </div>
      <% end %>

      <div :if={@matched_trans != []} class="flex flex-row">
        <div class="w-[82%]"></div>
        <div class="w-[10%] font-bold text-right px-1 border-t border-b-4 border-double border-black">
          {gettext("Balance")}
        </div>
        <div class="detail-amt-col font-bold text-right px-1 border-t border-b-4 border-double border-black">
          {Decimal.add(
            Ecto.Changeset.fetch_field!(@form.source, @doc_detail_amount),
            Enum.reduce(@matched_trans, 0, fn obj, acc ->
              if(obj.doc_type == "Receipt" or obj.doc_type == "CreditNote",
                do: Decimal.add(acc, obj.match_amount),
                else: Decimal.add(acc, Decimal.negate(obj.match_amount))
              )
            end)
          )
          |> Number.Delimit.number_to_delimited()}
        </div>
        <div class="detail-setting-col" />
      </div>
    </div>
    """
  end
end
