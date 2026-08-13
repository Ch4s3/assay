defmodule Assay.FileDescriptorLimitError do
  @moduledoc """
  Raised when Dialyzer fails to read a `.beam` file because the operating
  system refused to open it.

  Dialyzer hashes every `.beam` file in the analysed application tree to decide
  what the incremental PLT must rebuild. When the process runs out of file
  descriptors, `:beam_lib` returns a generic `{:error, :beam_lib, {:file_error,
  _, :emfile}}`, which Dialyzer reports as an opaque MD5 failure:

      Could not compute MD5 for .beam: _build/dev/lib/foo/ebin/Elixir.Foo.beam

  Nothing in that message points at the real cause. On macOS, where the default
  soft limit is 256 descriptors, it is almost always descriptor exhaustion
  rather than a corrupt build artifact, so this exception restates the failure
  with the `ulimit` invocation that fixes it.

  Detection is deliberately narrow. Only the unqualified MD5 message is
  translated; the `(debug_info missing)` and `(debug_info error)` variants
  describe genuine compilation problems and are left alone.
  """

  @suggested_limit 65_536

  defexception [:beam_file, :soft_limit, :original_message]

  @type t :: %__MODULE__{
          beam_file: String.t(),
          soft_limit: pos_integer() | nil,
          original_message: String.t()
        }

  @doc """
  Builds an exception from a raw `{:dialyzer_error, message}` payload.

  Returns `{:ok, error}` when the message is the unqualified MD5 failure *and*
  the host is macOS, and `:error` otherwise, so callers can fall back to
  reporting the original Dialyzer message unchanged.

  The current soft descriptor limit is read at this point, while it still
  reflects the environment the failing run used.
  """
  @spec from_dialyzer_error(String.t()) :: {:ok, t()} | :error
  def from_dialyzer_error(message) when is_binary(message) do
    with true <- macos?(),
         {:ok, beam_file} <- beam_file(message) do
      {:ok,
       %__MODULE__{
         beam_file: beam_file,
         soft_limit: soft_limit(),
         original_message: String.trim_trailing(message)
       }}
    else
      _ -> :error
    end
  end

  @impl true
  def message(%__MODULE__{soft_limit: soft_limit} = error)
      when is_integer(soft_limit) and soft_limit >= @suggested_limit do
    """
    Dialyzer could not read a .beam file:

        #{error.original_message}

    On macOS this usually means the open file descriptor limit was reached,
    but yours is already #{soft_limit}, so something else is likely wrong.
    Check that the file exists and is readable:

        ls -l #{error.beam_file}

    If it looks damaged, rebuild it:

        mix clean && mix compile\
    """
  end

  def message(%__MODULE__{} = error) do
    """
    Dialyzer could not read a .beam file:

        #{error.original_message}

    On macOS this is almost always the open file descriptor limit#{limit_clause(error.soft_limit)},
    not a corrupt build artifact. Dialyzer opens every .beam file in the
    analysed application tree, which overruns the default limit of 256.

    Raise the limit in your shell and re-run:

        ulimit -n #{@suggested_limit}

    This applies only to the current shell session.\
    """
  end

  defp limit_clause(nil), do: ""
  defp limit_clause(soft_limit), do: " (currently #{soft_limit})"

  @md5_prefix "Could not compute MD5 for .beam: "

  defp beam_file(message) do
    case String.split(message, @md5_prefix, parts: 2) do
      [_before, rest] -> {:ok, rest |> String.split("\n", parts: 2) |> hd() |> String.trim()}
      _ -> :error
    end
  end

  defp macos? do
    case Application.get_env(:assay, :os_type_override, :os.type()) do
      {:unix, :darwin} -> true
      _ -> false
    end
  end

  defp soft_limit do
    case Application.fetch_env(:assay, :file_descriptor_limit_override) do
      {:ok, override} -> override
      :error -> read_soft_limit()
    end
  end

  # `ulimit` is a shell builtin with no BEAM equivalent, so the limit has to
  # come from a subshell. This only runs on the failure path, and any problem
  # reading it simply drops the "currently N" detail from the message.
  defp read_soft_limit do
    case System.cmd("sh", ["-c", "ulimit -n"], stderr_to_stdout: true) do
      {output, 0} -> parse_limit(output)
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp parse_limit(output) do
    case output |> String.trim() |> Integer.parse() do
      {limit, ""} -> limit
      _ -> nil
    end
  end
end
