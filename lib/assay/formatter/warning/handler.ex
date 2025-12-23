defmodule Assay.Formatter.Warning.Handler do
  @moduledoc false

  alias Assay.Formatter.Warning.Result

  @callback render(entry :: map(), result :: Result.t(), opts :: keyword()) :: Result.t()
end
