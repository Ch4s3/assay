defmodule Assay.FileDescriptorLimitErrorTest do
  use ExUnit.Case, async: false

  alias Assay.FileDescriptorLimitError

  @beam "/app/_build/dev/lib/foo/ebin/Elixir.Foo.beam"
  @md5_error "Could not compute MD5 for .beam: #{@beam}\n"

  setup do
    Application.put_env(:assay, :os_type_override, {:unix, :darwin})

    on_exit(fn ->
      Application.delete_env(:assay, :os_type_override)
      Application.delete_env(:assay, :file_descriptor_limit_override)
    end)

    :ok
  end

  describe "from_dialyzer_error/1" do
    test "recognizes the unqualified MD5 failure on macOS and captures the .beam path" do
      assert {:ok, %FileDescriptorLimitError{} = error} =
               FileDescriptorLimitError.from_dialyzer_error(@md5_error)

      assert error.beam_file == @beam
      assert error.original_message == String.trim_trailing(@md5_error)
    end

    test "ignores the MD5 failure when the OS is not macOS" do
      Application.put_env(:assay, :os_type_override, {:unix, :linux})

      assert FileDescriptorLimitError.from_dialyzer_error(@md5_error) == :error
    end

    test "ignores the debug_info variants, which are not descriptor exhaustion" do
      missing =
        "Could not compute MD5 for .beam (debug_info missing): #{@beam}\n"

      backend_error =
        "Could not compute MD5 for .beam (debug_info error) - did you forget to " <>
          "set the debug_info compilation option? #{@beam} badarg\n"

      assert FileDescriptorLimitError.from_dialyzer_error(missing) == :error
      assert FileDescriptorLimitError.from_dialyzer_error(backend_error) == :error
    end

    test "ignores unrelated dialyzer errors" do
      assert FileDescriptorLimitError.from_dialyzer_error("File not found: #{@beam}\n") == :error
    end
  end

  describe "message/1" do
    test "reports the current soft limit and the ulimit command to run" do
      Application.put_env(:assay, :file_descriptor_limit_override, 256)

      {:ok, error} = FileDescriptorLimitError.from_dialyzer_error(@md5_error)
      message = Exception.message(error)

      assert message =~ @beam
      assert message =~ "currently 256"
      assert message =~ "ulimit -n 65536"
    end

    test "omits the current limit when it cannot be determined" do
      Application.put_env(:assay, :file_descriptor_limit_override, nil)

      {:ok, error} = FileDescriptorLimitError.from_dialyzer_error(@md5_error)
      message = Exception.message(error)

      refute message =~ "currently"
      assert message =~ "ulimit -n 65536"
    end

    test "stops blaming the limit when it is already generous" do
      Application.put_env(:assay, :file_descriptor_limit_override, 1_048_576)

      {:ok, error} = FileDescriptorLimitError.from_dialyzer_error(@md5_error)
      message = Exception.message(error)

      assert message =~ "already 1048576"
      refute message =~ "ulimit -n"
      refute message =~ "almost always"
    end
  end
end
