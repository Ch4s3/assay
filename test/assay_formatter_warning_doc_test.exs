defmodule Assay.Formatter.WarningDoctest do
  use ExUnit.Case, async: true

  doctest Assay.Formatter.Warning
  doctest Assay.Formatter.Helpers
end
