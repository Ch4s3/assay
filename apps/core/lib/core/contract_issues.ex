defmodule Core.ContractIssues do
  @moduledoc """
  Purposely invalid contracts used to exercise Assay's formatter in development.
  """

  @doc "Spec is narrower than success typing: triggers :warn_contract_subtype"
  @spec subtype_issue(:ok) :: :ok
  def subtype_issue(:ok), do: :ok
  def subtype_issue(:error), do: :error

  @doc "Spec is broader than success typing: triggers :warn_contract_supertype"
  @spec supertype_issue(:ok | :error) :: {:ok, term()}
  def supertype_issue(:ok), do: {:ok, :ok}
  def supertype_issue(:error), do: :error

  @doc "Spec and success typing disagree completely: triggers :warn_contract_not_equal"
  @spec diff_issue(integer()) :: :ok
  def diff_issue(value), do: {:ok, value}

  @doc "Arguments in contract do not overlap with implementation: triggers :warn_contract_types"
  @spec invalid_args_issue(:never_happens) :: :ok
  def invalid_args_issue(:ok), do: :ok

  @doc "Return type contradicts implementation: also triggers :warn_contract_types"
  @spec invalid_return_issue(:ok) :: :ok
  def invalid_return_issue(:ok), do: {:error, :not_ok}
end
