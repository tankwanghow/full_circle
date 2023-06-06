alias FullCircle.StdInterface
import Ecto.Query, warn: false

taxcode_data = [
  %{
    code: "IM",
    descriptions:
      "All goods imported into Malaysia are subjected to duties and/or GST. GST is calculated on the value which includes cost, insurance and freight plus the customs duty payable (if any), unless the imported goods are for storage in a licensed warehouse or Free Trade Zone, or imported under Warehouse Scheme, or under the Approved Trader Scheme. If you are a GST registered trader and have paid GST to Malaysia Customs on your imports, you can claim input tax deduction in your GST returns submitted to the Director General of Custom.",
    rate: 0.06,
    tax_type: "Purchase"
  },
  %{
    code: "IS",
    descriptions:
      "This refers to goods imported under the Approved Trader Scheme (ATS) and Approved Toll Manufacturer Scheme (ATMS), where GST is suspended when the trader imports the non-dutiable goods into Malaysia. These two schemes are designed to ease the cash flow of Trader Scheme (ATS) and Approved Toll Manufacturer Scheme (ATMS), who has significant imports.",
    rate: 0,
    tax_type: "Purchase"
  },
  %{
    code: "BL",
    descriptions:
      "This refers to GST incurred by a business but GST registered trader is not allowed to claim input tax incurred. The expenses are as following: The supply to or importation of a passenger car; The hiring of passenger car; Club subscription fees (including transfer fee) charged by sporting and recreational clubs; Medical and personal accident insurance premiums by your staff; Medical expenses incurred by your staff. Excluding those covered under the provision of the employees Social Security Act 1969, Workmens Compensation Act 1952 or under any collective agreement under the Industrial Relations Act 1967; Benefits provided to the family members or relatives of your staff; Entertainment expenses to a person other than employee and existing customer except entertainment expenses incurred by a person who is in the business of providing entertainment.",
    rate: 0.06,
    tax_type: "Purchase"
  },
  %{
    code: "NR",
    descriptions:
      "This refers to goods and services purchased from non-GST registered supplier/trader. A supplier/trader who is not registered for GST is not allowed to charge and collect GST. Under the GST model, any unauthorized collection of GST is an offence.",
    rate: 0,
    tax_type: "Purchase"
  },
  %{
    code: "ZP",
    descriptions:
      "This refers to goods and services purchased from GST registered suppliers where GST is charged at 0%. This is also commonly known as zero-rated purchases. The list as in the Appendix A1 to Budget 2014 Speech.",
    rate: 0,
    tax_type: "Purchase"
  },
  %{
    code: "EP",
    descriptions:
      "This refers to purchases in relation to residential properties or certain financial services where there no GST was charged (i.e. exempt from GST). Consequently, there is no input tax would be incurred on these supplies. Examples as in Appendix A2 Budget 2014 Speech.",
    rate: 0,
    tax_type: "Purchase"
  },
  %{
    code: "OP",
    descriptions:
      "This refers to purchase of goods outside the scope of GST. An example is purchase of goods overseas and the goods did not come into Malaysia, the purchase of a business transferred as a going concern. For purchase of goods overseas, there may be instances where tax is imposed by a foreign jurisdiction that is similar to GST (e.g. VAT). nonetheless, the GST registered trader is not allowed to claim input tax for GST/VAT incurred for such purchases. This is because the input tax is paid to a party outside Malaysia.",
    rate: 0,
    tax_type: "Purchase"
  },
  %{
    code: "TX-E43",
    descriptions:
      "This is only applicable to GST registered trader (group and ATS only) that makes both taxable and exempt supplies (or commonly known as partially exempt trader). TX-E43 should be used for transactions involving the payment of input tax that is directly attributable to the making Incidental Exempt Supplies. Incidental Exempt Supplies include interest income from deposits placed with a financial institution in Malaysia, realized foreign exchange gains or losses, first issue of bonds, first issue of shares through an Initial Public Offering and interest received from loans provided to employees, factoring receivables, money received from unit holders for units received by a unit trust etc.",
    rate: 0.06,
    tax_type: "Purchase"
  },
  %{
    code: "TX-N43",
    descriptions:
      "This is only applicable to GST registered trader that makes both taxable and exempt supplies (or commonly known as partially exempt trader). This refers to GST incurred that is not directly attributable to the making of taxable or exempt supplies (or commonly known as residual input tax). Example includes operation over-head for a development of mixed property (properties comprise of residential & commercial).",
    rate: 0.06,
    tax_type: "Purchase"
  },
  %{
    code: "TX-RE",
    descriptions:
      "This is only applicable to GST registered trader that makes both taxable and exempt supplies (or commonly known as partially exempt trader). This refers to GST incurred that is not directly attributable to the making of taxable or exempt supplies (or commonly known as residual input tax). Example includes operation over-head for a development of mixed property (properties comprise of residential & commercial).",
    rate: 0.06,
    tax_type: "Purchase"
  },
  %{
    code: "GP",
    descriptions:
      "Purchase within GST group registration, purchase made within a Warehouse Scheme etc.",
    rate: 0,
    tax_type: "Purchase"
  },
  %{
    code: "AJP",
    descriptions:
      "Any adjustment made to Input Tax such as bad debt relief & other input tax adjustments.",
    rate: 0.06,
    tax_type: "Purchase"
  },
  %{
    code: "ZRL",
    descriptions:
      "A GST registered supplier can zero-rate (i.e. charging GST at 0%) certain local supply of goods and services if such goods or services are included in the Goods and Services Tax (Zero Rate Supplies) Order 20XX. Examples includes sale of fish, cooking oil.",
    rate: 0,
    tax_type: "Sales"
  },
  %{
    code: "ZRE",
    descriptions:
      "A GST registered supplier can zero-rate (i.e. charging GST at 0%) the supply of goods and services if they export the goods out of Malaysia or the services fall within the description of international services. Examples includes sale of air-tickets and international freight charges.",
    rate: 0,
    tax_type: "Sales"
  },
  %{
    code: "ES43",
    descriptions:
      "This is only applicable to GST registered trader that makes both taxable and exempt supplies (or commonly known as partially exempt trader). This refers to exempt supplies made under incidental exempt supplies. Incidental Exempt Supplies include interest income from deposits placed with a financial institution in Malaysia, realized foreign exchange gains or losses, first issue of bonds, first issue of shares through an Initial Public Offering and interest received from loans provided to employees also include factoring receivables, money received from unit holders for units received by a unit trust etc.",
    rate: 0,
    tax_type: "Sales"
  },
  %{
    code: "DS",
    descriptions:
      "GST is chargeable on supplies of goods and services. For GST to be applicable there must be goods or services provided and a consideration paid in return. However, there are situations where a supply has taken place even though no goods or services are provided or no consideration is paid. These are known as deemed supplies. Examples include free gifts (more than RM500) and disposal of business assets without consideration.",
    rate: 0.06,
    tax_type: "Sales"
  },
  %{
    code: "OS",
    descriptions:
      "This refers to supplies (commonly known as out-of-scope supply) which are outside the scope and GST is therefore not chargeable. In general, they are transfer of business as a going concern, private transactions, third country sales (i.e. sale of goods from a place outside Malaysia to another place outside Malaysia).",
    rate: 0,
    tax_type: "Sales"
  },
  %{
    code: "ES",
    descriptions:
      "This refers to supplies which are exempt under GST. These supply include residential property, public transportation etc.",
    rate: 0,
    tax_type: "Sales"
  },
  %{
    code: "RS",
    descriptions: "This refers to supplies which are supply given relief from GST.",
    rate: 0,
    tax_type: "Sales"
  },
  %{
    code: "GS",
    descriptions:
      "This refers to supplies which are disregarded under GST. These supplies include supply within GST group registration, sales made within Warehouse Scheme etc.",
    rate: 0,
    tax_type: "Sales"
  },
  %{
    code: "AJS",
    descriptions:
      "Any adjustment made to Output Tax, Example such as longer period adjustment, bad debt recovered, outstanding invoices more than 6 months & other output tax adjustments.",
    rate: 0,
    tax_type: "Sales"
  },
  %{
    code: "TX",
    descriptions:
      "This refers to goods and/or services purchased from GST registered suppliers. The prevailing GST rate is 6% wef 01/04/2015. As it is a tax on final consumption, a GST registered trader will be able to claim credits for GST paid on goods or services supplied to them. The recoverable credits are called input tax. Examples include goods or services purchased for business purposes from GST registered traders.",
    rate: 0.06,
    tax_type: "Purchase"
  },
  %{
    code: "SR",
    descriptions:
      "A GST registered supplier must charge and account GST at 6% for all sales of goods and services made in Malaysia unless the supply qualifies for zero-rating, exemption or falls outside the scope of the proposed GST model. The GST collected from customer is called output tax. The value of sale and corresponding output tax must be reported in the GST returns.",
    rate: 0.06,
    tax_type: "Sales"
  }
]

alias FullCircle.Accounting.TaxCode
pur_rec =
  FullCircle.Repo.get_by!(
    FullCircle.Accounting.Account, name: "Purchase Tax Receivable"
  )

sal_pay =
  FullCircle.Repo.get_by!(
    FullCircle.Accounting.Account, name: "Sales Tax Payable"
  )

Enum.each(taxcode_data, fn data ->
  ac = if(data.tax_type == "Sales", do: sal_pay, else: pur_rec)

  data = Map.merge(data, %{account_id: ac.id, account_name: ac.name})

  StdInterface.create(TaxCode, "tax_code", data, %{id: 1}, %{id: 1})
end)
