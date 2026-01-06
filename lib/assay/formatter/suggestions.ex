defmodule Assay.Formatter.Suggestions do
  @moduledoc """
  Provides actionable, context-aware suggestions for fixing Dialyzer warnings.
  Extracts information from multiple sources in the warning entry to provide
  specific, helpful guidance.

  Data sources:
    - entry.code: Warning type
    - entry.raw: Structured Dialyzer data (types, positions, etc.)
    - entry.text: Formatted reason text
    - entry.path: Source file (for code analysis)
  """

  alias Assay.Formatter.Warning

  @spec for_warning(atom(), map()) :: [String.t()]
  def for_warning(code, entry) do
    suggestions =
      base_suggestions(code, entry)
      |> add_context_suggestions(code, entry)
      |> add_type_suggestions(code, entry)
      |> add_reason_suggestions(code, entry)
      |> add_code_suggestions(code, entry)

    format_suggestions(suggestions)
  end

  defp base_suggestions(:warn_return_no_exit, _entry) do
    [
      "This function will never return normally.",
      "",
      "Common causes:",
      "  • Infinite loop or recursion without base case",
      "  • Always raises an exception",
      "  • Always calls exit/1 or throw/1"
    ]
  end

  defp base_suggestions(:warn_not_called, entry) do
    function_name = extract_function_name(entry)

    suggestions = [
      "This function is never called.",
      "",
      "Possible fixes:",
      "  • Remove the function if it's unused",
      "  • Add @doc false if it's intentionally private",
      "  • Export it if it should be public",
      "  • Check for typos in call sites"
    ]

    if function_name do
      ["This function is never called.", "Function: #{function_name}"] ++ Enum.drop(suggestions, 1)
    else
      suggestions
    end
  end

  defp base_suggestions(:warn_matching, _entry) do
    [
      "This pattern match will never succeed.",
      "",
      "Possible fixes:",
      "  • Check the pattern matches the actual type",
      "  • Add a catch-all clause (_)",
      "  • Verify guard conditions are correct"
    ]
  end

  defp base_suggestions(:warn_failing_call, _entry) do
    [
      "The call arguments don't match the function's expected types."
    ]
  end

  defp base_suggestions(:warn_contract_not_equal, _entry) do
    [
      "The @spec contract doesn't match the inferred success typing.",
      "",
      "Review the diff above to see what differs."
    ]
  end

  defp base_suggestions(_code, _entry), do: []

  defp add_context_suggestions(suggestions, :warn_failing_call, entry) do
    case entry do
      %{raw: {:warn_failing_call, _loc, {:call, [module, fun, actual, positions, mode, expected | _]}}} ->
        # Extract all available context
        call_name = Warning.format_call(module, fun)
        position_info = format_positions(positions)
        type_diff = format_type_difference(actual, expected)
        mode_info = format_mode(mode)

        # Build detailed context block
        context_items = []
        |> maybe_add("  Function call: #{call_name}", true)
        |> maybe_add("  Problematic argument position(s): #{position_info}", not is_nil(position_info))
        |> maybe_add("  Type mismatch: #{type_diff}", not is_nil(type_diff))
        |> maybe_add("  Analysis mode: #{mode_info}", not is_nil(mode_info))

        context_lines =
          if Enum.empty?(context_items) do
            []
          else
            ["", "Context:"] ++ context_items
          end

        # Add specific fix suggestions based on positions
        fix_hints = suggest_argument_fixes(positions, actual, expected)

        suggestions ++ context_lines ++ fix_hints

      _ ->
        suggestions
    end
  end

  defp add_context_suggestions(suggestions, :warn_contract_types, entry) do
    case entry do
      %{
        raw:
          {:warn_contract_types, _loc,
           {:invalid_contract, [module, fun, arity, details, _contract_text, _success_text]}}
      } ->
        call_name = "#{Warning.format_call(module, fun)}/#{arity}"
        {issue_description, specific_parts} = extract_contract_issue_details(details)
        context_lines = build_contract_context_lines(call_name, issue_description)
        specific_suggestions = build_contract_specific_suggestions(specific_parts)

        suggestions ++ context_lines ++ specific_suggestions

      _ ->
        suggestions
    end
  end

  defp add_context_suggestions(suggestions, :warn_contract_subtype, entry) do
    case entry do
      %{raw: {:warn_contract_subtype, _loc, {:contract_subtype, [module, fun, arity, _contract, _success]}}} ->
        suggestions ++
          [
            "",
            "Context:",
            "  Function: #{Warning.format_call(module, fun)}/#{arity}",
            "  Issue: @spec is narrower (more restrictive) than inferred type",
            "",
            "  This means your @spec promises less than Dialyzer can prove.",
            "  Consider making the @spec more permissive to match the success typing."
          ]

      _ ->
        suggestions
    end
  end

  defp add_context_suggestions(suggestions, :warn_contract_supertype, entry) do
    case entry do
      %{raw: {:warn_contract_supertype, _loc, {:contract_supertype, [module, fun, arity, _contract, _success]}}} ->
        suggestions ++
          [
            "",
            "Context:",
            "  Function: #{Warning.format_call(module, fun)}/#{arity}",
            "  Issue: @spec is broader (more permissive) than inferred type",
            "",
            "  This means your @spec promises more than Dialyzer can prove.",
            "  Consider making the @spec more restrictive to match the success typing, or",
            "  fix the implementation to match the broader @spec."
          ]

      _ ->
        suggestions
    end
  end

  defp add_context_suggestions(suggestions, :warn_not_called, entry) do
    case entry do
      %{raw: {:warn_not_called, _loc, {module, fun, arity}}} ->
        call_name = "#{Warning.format_call(module, fun)}/#{arity}"

        suggestions ++
          [
            "",
            "Context:",
            "  Function: #{call_name}",
            "  This function is defined but never called anywhere in the codebase.",
            "",
            "  Check if:",
            "  • It's a public function that should be exported",
            "  • It's a private helper that's no longer needed",
            "  • There's a typo in call sites (e.g., `foo` vs `Foo`)",
            "  • It's part of a callback that's intentionally unused"
          ]

      _ ->
        suggestions
    end
  end

  defp add_context_suggestions(suggestions, :warn_matching, entry) do
    # warn_matching raw structure varies, but typically contains pattern info
    case entry do
      %{raw: {_, _loc, pattern_info}} ->
        pattern_context = extract_pattern_context(pattern_info)

        if pattern_context do
          suggestions ++
            [
              "",
              "Context:",
              "  Pattern: #{pattern_context}"
            ]
        else
          suggestions
        end

      _ ->
        suggestions
    end
  end

  defp add_context_suggestions(suggestions, _code, _entry), do: suggestions

  defp extract_contract_issue_details({:invalid_contract, {args, return?}}) when is_list(args) do
    parts = []
    |> maybe_add("argument(s) #{format_arg_positions(args)}", args != [])
    |> maybe_add("return type", return?)

    desc =
      case parts do
        [] -> "contract contradicts success typing"
        [single] -> "invalid contract for #{single}"
        _ -> "invalid contract for #{Enum.join(parts, " and ")}"
      end

    {desc, %{args: args, return?: return?}}
  end

  defp extract_contract_issue_details(:none) do
    {"contract cannot be verified", %{}}
  end

  defp extract_contract_issue_details(other) do
    {"contract issue: #{inspect(other)}", %{}}
  end

  defp build_contract_context_lines(call_name, issue_description) do
    [
      "",
      "Context:",
      "  Function: #{call_name}",
      "  Issue: #{issue_description}"
    ]
  end

  defp build_contract_specific_suggestions(%{args: args, return?: return?})
       when args != [] or return? do
    suggestions = [
      "",
      "Specific guidance:",
      "  • Compare contract vs success typing above"
    ]

    suggestions
    |> maybe_add("  • Check @spec for #{format_arg_positions(args)} argument(s)", args != [])
    |> maybe_add("  • Check @spec return type matches implementation", return?)
  end

  defp build_contract_specific_suggestions(_), do: []

  defp format_mode(:only_sig), do: "only signature available (no implementation)"
  defp format_mode(_), do: nil

  defp suggest_argument_fixes(positions, _actual, _expected) when is_list(positions) and positions != [] do
    if length(positions) > 1 do
      [
        "",
        "Note: Multiple arguments have type mismatches."
      ]
    else
      []
    end
  end

  defp suggest_argument_fixes(_, _, _), do: []

  defp extract_pattern_context({:pattern, info}) when is_list(info), do: inspect(info)
  defp extract_pattern_context(info) when is_binary(info), do: info
  defp extract_pattern_context(_), do: nil

  defp add_type_suggestions(suggestions, :warn_failing_call, entry) do
    case entry do
      %{raw: {:warn_failing_call, _loc, {:call, [_module, _fun, actual, _positions, _mode, expected | _]}}} ->
        type_hint = suggest_type_fix(actual, expected)
        if type_hint do
          suggestions ++ ["", "Type hint:", "  #{type_hint}"]
        else
          suggestions
        end

      _ ->
        suggestions
    end
  end

  defp add_type_suggestions(suggestions, _code, _entry), do: suggestions

  defp add_reason_suggestions(suggestions, code, entry)
       when code in [:warn_failing_call, :warn_return_no_exit] do
    reason = Warning.extract_reason_line(entry)

    case reason do
      reason when is_binary(reason) ->
        specific_suggestion =
          cond do
            String.contains?(reason, "guard fails") ->
              "A guard condition will always fail. Review the guard expression."

            String.contains?(reason, "no local return") ->
              "Check for infinite loops or missing base cases."

            true ->
              nil
          end

        if specific_suggestion do
          suggestions ++ ["", "Note:", "  #{specific_suggestion}"]
        else
          suggestions
        end

      _ ->
        suggestions
    end
  end

  defp add_reason_suggestions(suggestions, _code, _entry), do: suggestions

  defp add_code_suggestions(suggestions, :warn_return_no_exit, entry) do
    case entry.path do
      path when is_binary(path) and path != "" ->
        case analyze_source_for_patterns(path, entry.line, entry.column) do
          {:infinite_loop, details} ->
            suggestions ++
              [
                "",
                "Code analysis:",
                "  Detected potential infinite loop:",
                "  #{details}",
                "",
                "  Look for:",
                "  • `while true do ... end` without break conditions",
                "  • `loop do ... end` without exit conditions",
                "  • Recursive calls without base cases"
              ]

          {:missing_base_case, details} ->
            suggestions ++
              [
                "",
                "Code analysis:",
                "  Recursive function may be missing base case:",
                "  #{details}",
                "",
                "  Ensure there's a pattern match or condition that returns",
                "  without making another recursive call."
              ]

          {:always_raises, details} ->
            suggestions ++
              [
                "",
                "Code analysis:",
                "  Function only raises exceptions:",
                "  #{details}",
                "",
                "  If this is intentional, consider:",
                "  • Using @dialyzer {:nowarn_function, ...} to suppress",
                "  • Documenting that this function always raises",
                "  • Returning {:error, reason} instead of raising"
              ]

          {:unreachable_code, details} ->
            suggestions ++
              [
                "",
                "Code analysis:",
                "  Code after exit/raise is unreachable:",
                "  #{details}",
                "",
                "  Remove unreachable code or restructure the function."
              ]

          _ ->
            suggestions
        end

      _ ->
        suggestions
    end
  end

  defp add_code_suggestions(suggestions, :warn_matching, entry) do
    case entry.path do
      path when is_binary(path) and path != "" ->
        case analyze_pattern_match(path, entry.line, entry.column) do
          {:guard_failure, details} ->
            suggestions ++
              [
                "",
                "Code analysis:",
                "  Pattern match guard will always fail:",
                "  #{details}",
                "",
                "  Check the guard condition - it may be checking for an",
                "  impossible condition given the pattern's type."
              ]

          {:type_mismatch, details} ->
            suggestions ++
              [
                "",
                "Code analysis:",
                "  Pattern type doesn't match actual type:",
                "  #{details}",
                "",
                "  The pattern expects a different type than what's actually",
                "  passed. Consider using a different pattern or type guard."
              ]

          _ ->
            suggestions
        end

      _ ->
        suggestions
    end
  end

  defp add_code_suggestions(suggestions, _code, _entry), do: suggestions

  defp extract_function_name(entry) do
    case entry.text do
      text when is_binary(text) ->
        case Regex.run(~r/Function\s+([A-Z][\w\.]+\.[\w!?]+)\/(\d+)/, text) do
          [_, call, _arity] -> call
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp format_positions(positions) when is_list(positions) and positions != [] do
    positions
    |> Enum.map(&ordinal/1)
    |> case do
      [single] -> single
      list -> Enum.join(list, ", ")
    end
  end

  defp format_positions(_), do: nil

  defp format_type_difference(actual, expected) when is_binary(actual) and is_binary(expected) do
    format_type_difference_binary(actual, expected)
  end

  defp format_type_difference(actual, expected) when is_list(actual) and is_list(expected) do
    format_type_difference(
      IO.chardata_to_string(actual),
      IO.chardata_to_string(expected)
    )
  end

  defp format_type_difference(_, _), do: nil

  defp format_type_difference_binary(actual, expected) do
    cond do
      binary_to_integer?(actual, expected) ->
        "You're passing a string but an integer is expected"

      integer_to_binary?(actual, expected) ->
        "You're passing an integer but a string is expected"

      string_to_atom?(actual, expected) ->
        "You're passing a string but an atom is expected"

      true ->
        nil
    end
  end

  defp binary_to_integer?(actual, expected) do
    String.contains?(actual, "binary()") and String.contains?(expected, "integer()")
  end

  defp integer_to_binary?(actual, expected) do
    String.contains?(actual, "integer()") and String.contains?(expected, "binary()")
  end

  defp string_to_atom?(actual, expected) do
    (String.contains?(actual, ~s(")) or String.contains?(actual, "binary()")) and
      String.contains?(expected, "atom()")
  end

  defp suggest_type_fix(actual, expected) when is_binary(actual) and is_binary(expected) do
    suggest_type_fix_binary(actual, expected)
  end

  defp suggest_type_fix(actual, expected) when is_list(actual) and is_list(expected) do
    suggest_type_fix(IO.chardata_to_string(actual), IO.chardata_to_string(expected))
  end

  defp suggest_type_fix(_, _), do: nil

  defp suggest_type_fix_binary(actual, expected) do
    cond do
      binary_to_integer?(actual, expected) ->
        "Consider converting the string to an integer (e.g., String.to_integer/1)"

      integer_to_binary?(actual, expected) ->
        "Consider converting the integer to a string (e.g., Integer.to_string/1)"

      string_to_atom?(actual, expected) ->
        "Consider using an atom instead (e.g., `:title` instead of `\"title\"`)"

      true ->
        nil
    end
  end

  defp format_arg_positions(args) when is_list(args) do
    args
    |> Enum.map(&ordinal/1)
    |> case do
      [single] -> single
      [first, second] -> "#{first} and #{second}"
      list -> "#{Enum.join(Enum.take(list, -2), ", ")} and #{List.last(list)}"
    end
  end

  defp format_arg_positions(_), do: ""

  defp ordinal(1), do: "1st"
  defp ordinal(2), do: "2nd"
  defp ordinal(3), do: "3rd"
  defp ordinal(n) when is_integer(n), do: "#{n}th"
  defp ordinal(_), do: ""

  defp maybe_add(list, item, true), do: list ++ [item]
  defp maybe_add(list, _item, false), do: list

  defp analyze_source_for_patterns(path, line, _column) do
    with true <- File.regular?(path),
         {:ok, contents} <- File.read(path) do
      lines = String.split(contents, "\n", trim: false)
      target_line_num = line || 1
      target_line = Enum.at(lines, target_line_num - 1)

      # Get function context (find the function definition containing this line)
      function_context = find_function_context(lines, target_line_num)

      # Analyze the function body for patterns
      cond do
        # Pattern 1: Infinite loop detection
        detect_infinite_loop?(lines, target_line_num, function_context) ->
          {:infinite_loop, format_loop_details(target_line, function_context)}

        # Pattern 2: Missing base case in recursion
        detect_missing_base_case?(lines, target_line_num, function_context) ->
          {:missing_base_case, format_recursion_details(target_line, function_context)}

        # Pattern 3: Always raises
        detect_always_raises?(lines, target_line_num, function_context) ->
          {:always_raises, format_raise_details(target_line, function_context)}

        # Pattern 4: Unreachable code after exit/raise
        detect_unreachable_code?(lines, target_line_num, function_context) ->
          {:unreachable_code, format_unreachable_details(target_line, function_context)}

        true ->
          :no_pattern
      end
    else
      _ -> :no_pattern
    end
  end

  defp find_function_context(lines, target_line_num) do
    # Look backwards from target line to find function definition
    Enum.take(lines, target_line_num)
    |> Enum.reverse()
    |> Enum.reduce_while(nil, fn line, acc ->
      cond do
        # Found function definition
        Regex.match?(~r/^\s*def(p?)\s+/, line) ->
          lines_seen = length(acc || [])
          {:halt, %{start_line: target_line_num - lines_seen, line: line}}

        # Found module boundary (stop searching)
        Regex.match?(~r/^\s*defmodule\s+/, line) ->
          {:halt, acc}

        true ->
          {:cont, [line | (acc || [])]}
      end
    end)
  end

  defp detect_infinite_loop?(lines, target_line_num, function_context) do
    target_line = Enum.at(lines, target_line_num - 1)

    # Check for common infinite loop patterns
    cond do
      # `while true do ... end` without break
      Regex.match?(~r/while\s+true\s+do/, target_line) ->
        # Check if there's a break/return in the loop body
        function_body = get_function_body(lines, function_context, target_line_num)
        not has_break_condition?(function_body)

      # `loop do ... end` without exit
      Regex.match?(~r/loop\s+do/, target_line) ->
        function_body = get_function_body(lines, function_context, target_line_num)
        not has_exit_condition?(function_body)

      # Recursive call without base case (checked separately)
      true ->
        false
    end
  end

  defp detect_missing_base_case?(lines, target_line_num, function_context) do
    function_body = get_function_body(lines, function_context, target_line_num)

    # Check if function calls itself
    if contains_recursive_call?(function_body, function_context) do
      # Check if there's a base case (early return without recursion)
      not has_base_case?(function_body, function_context)
    else
      false
    end
  end

  defp detect_always_raises?(lines, target_line_num, function_context) do
    function_body = get_function_body(lines, function_context, target_line_num)

    # Check if all code paths raise/exit/throw
    all_paths_raise?(function_body)
  end

  defp detect_unreachable_code?(lines, target_line_num, _function_context) do
    # Check if this line is after an exit/raise/throw
    lines_before = Enum.take(lines, target_line_num - 1)
    Enum.any?(lines_before, fn line ->
      Regex.match?(~r/\b(exit|raise|throw)\s*\(/, line)
    end)
  end

  defp get_function_body(lines, %{start_line: start}, target_line_num) do
    # Get lines from function start to target (or end of function if we can detect it)
    Enum.slice(lines, start - 1, target_line_num - start + 1)
  end

  defp get_function_body(_lines, _context, _target), do: []

  defp has_break_condition?(body_lines) do
    body_text = Enum.join(body_lines, "\n")

    # Look for common break patterns
    Regex.match?(~r/\b(break|return|exit|raise)\b/, body_text) or
      Regex.match?(~r/if\s+.*\s+do\s+.*\s+(break|return|exit)/, body_text)
  end

  defp has_exit_condition?(body_lines) do
    body_text = Enum.join(body_lines, "\n")

    # Look for receive with timeout, cond with exit, etc.
    Regex.match?(~r/receive\s+.*\safter/, body_text) or
      Regex.match?(~r/cond\s+do/, body_text) or
      has_break_condition?(body_lines)
  end

  defp contains_recursive_call?(body_lines, %{line: def_line}) do
    # Extract function name from definition
    case Regex.run(~r/def(p?)\s+([\w!?]+)/, def_line) do
      [_, _, fun_name] ->
        body_text = Enum.join(body_lines, "\n")
        # Check if function calls itself
        Regex.match?(~r/\b#{fun_name}\s*\(/, body_text)

      _ ->
        false
    end
  end

  defp contains_recursive_call?(_body_lines, _context), do: false

  defp has_base_case?(body_lines, function_context) do
    # Look for early returns before recursive calls
    # This is a simplified check - could be enhanced
    lines_with_recursion =
      body_lines
      |> Enum.with_index()
      |> Enum.filter(fn {line, _} ->
        contains_recursive_call?([line], function_context)
      end)

    # Check if there are returns before recursion
    if lines_with_recursion != [] do
      first_recursion_idx = lines_with_recursion |> hd() |> elem(1)

      # Check if there's a return/pattern match before recursion
      Enum.slice(body_lines, 0, first_recursion_idx)
      |> Enum.any?(fn line ->
        # Early return patterns
        Regex.match?(~r/\b(return|when.*->)/, line) or
          # Pattern match that doesn't recurse
          Regex.match?(~r/^\s*[^#]*->\s*[^#]*$/, line)
      end)
    else
      false
    end
  end

  defp all_paths_raise?(body_lines) do
    body_text = Enum.join(body_lines, "\n")

    # Count raise/exit/throw vs return patterns
    raise_count =
      body_text
      |> String.split("\n")
      |> Enum.count(&Regex.match?(~r/\b(raise|exit|throw)\s*\(/, &1))

    return_count =
      body_text
      |> String.split("\n")
      |> Enum.count(&Regex.match?(~r/->\s*[^#]*$/, &1))

    # If we have raises but no returns, likely always raises
    raise_count > 0 and return_count == 0
  end

  defp format_loop_details(_line, _context) do
    "Line contains a loop construct that may never terminate. " <>
      "Check for break conditions or exit criteria."
  end

  defp format_recursion_details(_line, _context) do
    "Recursive function appears to be missing a base case. " <>
      "Ensure there's a pattern match or condition that returns without recursion."
  end

  defp format_raise_details(_line, _context) do
    "Function only contains raise/exit/throw calls. " <>
      "No code path returns normally."
  end

  defp format_unreachable_details(_line, _context) do
    "Code after an exit/raise/throw statement is unreachable."
  end

  defp analyze_pattern_match(path, line, _column) do
    with true <- File.regular?(path),
         {:ok, contents} <- File.read(path) do
      lines = String.split(contents, "\n", trim: false)
      target_line = Enum.at(lines, (line || 1) - 1)

      cond do
        # Check for guard that always fails
        Regex.match?(~r/when\s+.*==\s+.*==/, target_line) ->
          {:guard_failure, "Guard condition contains logical error (e.g., `x == y == z`)"}

        # Check for type mismatch in pattern
        Regex.match?(~r/%\{.*\}\s*=\s*[^%]/, target_line) ->
          {:type_mismatch, "Pattern expects a map but receives a different type"}

        true ->
          :no_pattern
      end
    else
      _ -> :no_pattern
    end
  end

  defp format_suggestions([]), do: []
  defp format_suggestions(suggestions) do
    ["", "Suggestion:"] ++ Enum.map(suggestions, &"  #{&1}")
  end
end
