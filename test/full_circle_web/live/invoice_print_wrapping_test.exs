defmodule FullCircleWeb.InvoicePrintWrappingTest do
  @moduledoc """
  Print pagination estimates row height from the description text. `.detail-desc`
  is `white-space: normal` at full width, so a long description wraps and the row
  grows — assuming a single line silently overflows `.details-body`.
  """
  use ExUnit.Case, async: true

  alias FullCircleWeb.InvoiceLive.Print

  # Must match @desc_chars_per_line in the module under test
  @per_line 95

  test "short description is one line" do
    assert Print.desc_line_count("Delivered to site") == 1
  end

  test "text exactly filling one line does not spill to two" do
    assert Print.desc_line_count(String.duplicate("a", @per_line)) == 1
  end

  test "one character past the limit wraps to two lines" do
    assert Print.desc_line_count(String.duplicate("a", @per_line + 1)) == 2
  end

  test "long description wraps proportionally" do
    assert Print.desc_line_count(String.duplicate("a", @per_line * 3)) == 3
    assert Print.desc_line_count(String.duplicate("a", @per_line * 3 + 1)) == 4
  end

  test "explicit newlines each start a new line" do
    assert Print.desc_line_count("one\ntwo\nthree") == 3
    assert Print.desc_line_count("one\r\ntwo") == 2
  end

  test "newlines and wrapping combine" do
    long = String.duplicate("a", @per_line * 2)
    assert Print.desc_line_count("short\n" <> long) == 3
  end

  test "blank and whitespace-only text still occupies one line" do
    assert Print.desc_line_count("") == 1
    assert Print.desc_line_count("   ") == 1
  end
end
