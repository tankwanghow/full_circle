defmodule FullCircle.BankPayment.Banks do
  @moduledoc """
  Malaysian banks for supplier bank details: name, BIC and valid savings/current
  account number lengths, from PB enterprise's "Interbank GIRO (IBG)
  Participating Financial Institutions" list, plus Public Bank and Public
  Islamic Bank, which that list leaves out because it is Public Bank's own.
  """

  # {full name, short name, BIC, valid savings/current account lengths}
  @banks [
    {"Affin Bank Berhad", "Affin", "PHBMMYKL", [12]},
    {"Affin Islamic Bank Berhad", "Affin Islamic", "AIBBMYKL", [12]},
    {"Agrobank (Bank Pertanian Malaysia Berhad)", "Agrobank", "AGOBMYKL", [16]},
    {"Al Rajhi Banking & Investment Corporation (Malaysia) Berhad", "Al Rajhi", "RJHIMYKL", [15]},
    {"Alliance Bank Malaysia Berhad", "Alliance", "MFBBMYKL", [15]},
    {"Alliance Islamic Bank Berhad", "Alliance Islamic", "ALSRMYKL", [15]},
    {"AmBank (M) Berhad", "AmBank", "ARBKMYKL", [13]},
    {"AmBank Islamic Berhad", "AmBank Islamic", "AISLMYKL", [13]},
    {"Bangkok Bank Berhad", "Bangkok Bank", "BKKBMYKL", [13]},
    {"Bank Islam Malaysia Berhad", "Bank Islam", "BIMBMYKL", [14]},
    {"Bank Kerjasama Rakyat Malaysia Berhad", "Bank Rakyat", "BKRMMYKL", [12]},
    {"Bank Muamalat Malaysia Berhad", "Muamalat", "BMMBMYKL", [14]},
    {"Bank of America Malaysia Berhad", "Bank of America", "BOFAMY2X", Enum.to_list(5..17)},
    {"Bank of China (Malaysia) Berhad", "Bank of China", "BKCHMYKL", [13, 15]},
    {"Bank Simpanan Nasional", "BSN", "BSNAMYK1", [16]},
    {"BNP Paribas Malaysia Berhad", "BNP Paribas", "BNPAMYKL", Enum.to_list(6..16)},
    {"China Construction Bank (Malaysia) Berhad", "CCB", "PCBCMYKL", [12]},
    {"CIMB Bank Berhad", "CIMB", "CIBBMYKL", [10, 14]},
    {"CIMB Islamic Bank Berhad", "CIMB Islamic", "CTBBMYKL", [10, 14]},
    {"Citibank Berhad", "Citibank", "CITIMYKL", Enum.to_list(9..16)},
    {"Deutsche Bank (Malaysia) Berhad", "Deutsche", "DEUTMYKL", Enum.to_list(10..17)},
    {"Hong Leong Bank Berhad", "Hong Leong", "HLBBMYKL", [11, 13]},
    {"Hong Leong Islamic Bank Berhad", "Hong Leong Islamic", "HLIBMYKL", [11, 13]},
    {"HSBC Amanah Malaysia Berhad", "HSBC Amanah", "HMABMYKL", [12, 13, 14, 15, 17]},
    {"HSBC Bank Malaysia Berhad", "HSBC", "HBMBMYKL", [12, 13, 14, 15, 17]},
    {"Industrial and Commercial Bank of China (Malaysia) Berhad", "ICBC", "ICBKMYKL", [19]},
    {"J.P. Morgan Chase Bank Berhad", "J.P. Morgan", "CHASMYKX", Enum.to_list(10..17)},
    {"Kuwait Finance House (Malaysia) Berhad", "KFH", "KFHOMYKL", [12]},
    {"Malayan Banking Berhad (Maybank)", "Maybank", "MBBEMYKL", [12]},
    {"Maybank Islamic Berhad", "Maybank Islamic", "MBISMYKL", [12]},
    {"MBSB Bank Berhad", "MBSB", "AFBQMYKL", [16]},
    {"Mizuho Bank (Malaysia) Berhad", "Mizuho", "MHCBMYKA", [10]},
    {"MUFG Bank (Malaysia) Berhad", "MUFG", "BOTKMYKX", [6]},
    {"OCBC Al-Amin Bank Berhad", "OCBC Al-Amin", "OABBMYKL", Enum.to_list(9..17)},
    {"OCBC Bank (Malaysia) Berhad", "OCBC", "OCBCMYKL", Enum.to_list(9..17)},
    {"Public Bank Berhad", "Public Bank", "PBBEMYKL", [10]},
    {"Public Islamic Bank Berhad", "Public Islamic", "PIBEMYK1", [10]},
    {"RHB Bank Berhad", "RHB", "RHBBMYKL", [14]},
    {"RHB Islamic Bank Berhad", "RHB Islamic", "RHBAMYKL", [14]},
    {"Standard Chartered Bank Malaysia Berhad", "Std Chartered", "SCBLMYKX", Enum.to_list(5..17)},
    {"Standard Chartered Saadiq Berhad", "SC Saadiq", "SCSRMYKK", Enum.to_list(5..17)},
    {"Sumitomo Mitsui Banking Corporation Malaysia Berhad", "SMBC", "SMBCMYKL", [8]},
    {"United Overseas Bank (Malaysia) Berhad", "UOB", "UOVBMYKL", [7, 9, 10, 11, 12, 13, 14, 17]},
    {"YTL Digital Bank Berhad (Ryt Bank)", "Ryt Bank", "SCCHMYKL", [10]}
  ]

  def all,
    do:
      Enum.map(@banks, fn {name, short, bic, lengths} ->
        %{name: name, short: short, bic: bic, lengths: lengths}
      end)

  def get(nil), do: nil
  def get(bic), do: Enum.find(all(), &(&1.bic == bic))

  def name(bic) do
    case get(bic) do
      nil -> nil
      bank -> bank.name
    end
  end

  @doc "Short name for tight screens, e.g. \"Maybank\" for MBBEMYKL."
  def short_name(bic) do
    case get(bic) do
      nil -> nil
      bank -> bank.short
    end
  end

  def options, do: Enum.map(all(), &{&1.name, &1.bic})
end
