defmodule FullCircle.BankPayment.Banks do
  @moduledoc """
  Malaysian banks for supplier bank details: name, BIC and valid savings/current
  account number lengths, from PB enterprise's "Interbank GIRO (IBG)
  Participating Financial Institutions" list, plus Public Bank and Public
  Islamic Bank, which that list leaves out because it is Public Bank's own.
  """

  @banks [
    {"Affin Bank Berhad", "PHBMMYKL", [12]},
    {"Affin Islamic Bank Berhad", "AIBBMYKL", [12]},
    {"Agrobank (Bank Pertanian Malaysia Berhad)", "AGOBMYKL", [16]},
    {"Al Rajhi Banking & Investment Corporation (Malaysia) Berhad", "RJHIMYKL", [15]},
    {"Alliance Bank Malaysia Berhad", "MFBBMYKL", [15]},
    {"Alliance Islamic Bank Berhad", "ALSRMYKL", [15]},
    {"AmBank (M) Berhad", "ARBKMYKL", [13]},
    {"AmBank Islamic Berhad", "AISLMYKL", [13]},
    {"Bangkok Bank Berhad", "BKKBMYKL", [13]},
    {"Bank Islam Malaysia Berhad", "BIMBMYKL", [14]},
    {"Bank Kerjasama Rakyat Malaysia Berhad", "BKRMMYKL", [12]},
    {"Bank Muamalat Malaysia Berhad", "BMMBMYKL", [14]},
    {"Bank of America Malaysia Berhad", "BOFAMY2X", Enum.to_list(5..17)},
    {"Bank of China (Malaysia) Berhad", "BKCHMYKL", [13, 15]},
    {"Bank Simpanan Nasional", "BSNAMYK1", [16]},
    {"BNP Paribas Malaysia Berhad", "BNPAMYKL", Enum.to_list(6..16)},
    {"China Construction Bank (Malaysia) Berhad", "PCBCMYKL", [12]},
    {"CIMB Bank Berhad", "CIBBMYKL", [10, 14]},
    {"CIMB Islamic Bank Berhad", "CTBBMYKL", [10, 14]},
    {"Citibank Berhad", "CITIMYKL", Enum.to_list(9..16)},
    {"Deutsche Bank (Malaysia) Berhad", "DEUTMYKL", Enum.to_list(10..17)},
    {"Hong Leong Bank Berhad", "HLBBMYKL", [11, 13]},
    {"Hong Leong Islamic Bank Berhad", "HLIBMYKL", [11, 13]},
    {"HSBC Amanah Malaysia Berhad", "HMABMYKL", [12, 13, 14, 15, 17]},
    {"HSBC Bank Malaysia Berhad", "HBMBMYKL", [12, 13, 14, 15, 17]},
    {"Industrial and Commercial Bank of China (Malaysia) Berhad", "ICBKMYKL", [19]},
    {"J.P. Morgan Chase Bank Berhad", "CHASMYKX", Enum.to_list(10..17)},
    {"Kuwait Finance House (Malaysia) Berhad", "KFHOMYKL", [12]},
    {"Malayan Banking Berhad (Maybank)", "MBBEMYKL", [12]},
    {"Maybank Islamic Berhad", "MBISMYKL", [12]},
    {"MBSB Bank Berhad", "AFBQMYKL", [16]},
    {"Mizuho Bank (Malaysia) Berhad", "MHCBMYKA", [10]},
    {"MUFG Bank (Malaysia) Berhad", "BOTKMYKX", [6]},
    {"OCBC Al-Amin Bank Berhad", "OABBMYKL", Enum.to_list(9..17)},
    {"OCBC Bank (Malaysia) Berhad", "OCBCMYKL", Enum.to_list(9..17)},
    {"Public Bank Berhad", "PBBEMYKL", [10]},
    {"Public Islamic Bank Berhad", "PIBEMYK1", [10]},
    {"RHB Bank Berhad", "RHBBMYKL", [14]},
    {"RHB Islamic Bank Berhad", "RHBAMYKL", [14]},
    {"Standard Chartered Bank Malaysia Berhad", "SCBLMYKX", Enum.to_list(5..17)},
    {"Standard Chartered Saadiq Berhad", "SCSRMYKK", Enum.to_list(5..17)},
    {"Sumitomo Mitsui Banking Corporation Malaysia Berhad", "SMBCMYKL", [8]},
    {"United Overseas Bank (Malaysia) Berhad", "UOVBMYKL", [7, 9, 10, 11, 12, 13, 14, 17]},
    {"YTL Digital Bank Berhad (Ryt Bank)", "SCCHMYKL", [10]}
  ]

  def all,
    do: Enum.map(@banks, fn {name, bic, lengths} -> %{name: name, bic: bic, lengths: lengths} end)

  def get(nil), do: nil
  def get(bic), do: Enum.find(all(), &(&1.bic == bic))

  def name(bic) do
    case get(bic) do
      nil -> nil
      bank -> bank.name
    end
  end

  def options, do: Enum.map(all(), &{&1.name, &1.bic})
end
