defmodule FullCircle.Reporting.AgingBuckets do
  @presets %{
    "15/30/45/60" => [15, 30, 45, 60],
    "30/60/90/120" => [30, 60, 90, 120],
    "60/90/120/180" => [60, 90, 120, 180]
  }

  @default_preset "30/60/90/120"
  @custom_label "Custom"

  def presets, do: @presets
  def default_preset, do: @default_preset
  def default_cutoffs, do: @presets[@default_preset]
  def preset_options, do: [@custom_label | Map.keys(@presets)]

  def parse_cutoffs(params) do
    cond do
      params["c1"] && params["c2"] && params["c3"] && params["c4"] ->
        sanitize([params["c1"], params["c2"], params["c3"], params["c4"]])

      params["preset"] && Map.has_key?(@presets, params["preset"]) ->
        @presets[params["preset"]]

      params["days"] ->
        d = to_int(params["days"], 15)
        [d, d * 2, d * 3, d * 4]

      true ->
        default_cutoffs()
    end
  end

  def preset_for(cutoffs) do
    Enum.find_value(@presets, @custom_label, fn {name, cs} -> if cs == cutoffs, do: name end)
  end

  def bucket_labels([c1, c2, c3, c4]) do
    ["0-#{c1}", "#{c1 + 1}-#{c2}", "#{c2 + 1}-#{c3}", "#{c3 + 1}-#{c4}", "#{c4}+"]
  end

  defp sanitize(values) do
    list = Enum.map(values, &to_int(&1, 0))

    case list do
      [c1, c2, c3, c4] when c1 >= 0 and c1 < c2 and c2 < c3 and c3 < c4 -> list
      _ -> default_cutoffs()
    end
  end

  defp to_int(v, default) when is_binary(v) do
    case Integer.parse(v) do
      {n, _} -> n
      :error -> default
    end
  end

  defp to_int(v, _default) when is_integer(v), do: v
  defp to_int(_, default), do: default
end
