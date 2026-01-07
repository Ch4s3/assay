defmodule Assay.Doctest do
  use ExUnit.Case, async: true

  doctest Assay.Formatter.Suggestions
  doctest Assay.Formatter.Warning
  doctest Assay.Formatter.Helpers
  doctest Assay.Ignore
  doctest Assay.Config
end
