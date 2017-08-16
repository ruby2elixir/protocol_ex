defmodule ProtocolEx do
  @moduledoc """
  Matcher protocol control module
  """


  defmodule InvalidProtocolSpecification do
    @moduledoc """
    This is raised when a protocol definition is invalid.

    If a new feature is wanted in the protocol definition, please raise an issue or submit a PR.
    """
    defexception [ast: nil]
    def message(exc), do: "Unhandled specification node:  #{inspect exc.ast}"
  end

  defmodule DuplicateSpecification do
    @moduledoc """
    Only one implementation for a given callback per implementaiton is allowed at this time.
    """
    defexception [name: nil, arity: 0]
    def message(exc), do: "Duplicate specification node:  #{inspect exc.name}/#{inspect exc.arity}"
  end

  defmodule UnimplementedProtocolEx do
    @moduledoc """
    Somehow a given implementation was consolidated without actually having a required callback specified.
    """
    defexception [proto: nil, name: nil, arity: 0, value: nil]
    def message(exc), do: "Unimplemented Protocol of `#{exc.proto}` at #{inspect exc.name}/#{inspect exc.arity} of value: #{inspect exc.value}"
  end

  defmodule MissingRequiredProtocolDefinition do
    @moduledoc """
    The given implementation is missing a required callback from the protocol.
    """
    defexception [proto: nil, impl: nil, name: nil, arity: -1]
    def message(exc) do
      impl = String.replace_prefix(to_string(exc.impl), to_string(exc.proto)<>".", "")
      "On Protocol `#{exc.proto}` missing a required protocol callback on `#{impl}` of:  #{exc.name}/#{exc.arity}"
    end
  end


  defmodule Spec do
    @moduledoc false
    defstruct [callbacks: []]
  end


  @desc_name :"$ProtocolEx_description$"
  @desc_attr :protocol_ex_desc


  @doc """
  Define a protocol behaviour.
  """
  defmacro defprotocolEx(name, [do: body]) do
    parsed_name = get_atom_name(name)
    # desc_name = get_desc_name(parsed_name)
    desc_name = get_atom_name_with(name, @desc_name)
    body =
      case body do
        {:__block__, meta, lines} ->
          lines = Enum.map(lines, fn
            {type, _, _} = ast when type in [:def] -> ast
            ast -> Macro.expand(ast, __CALLER__)
          end)
          {:__block__, meta, lines}
      end
    spec = decompose_spec(body)
    spec = verify_valid_spec(spec)
    quote do
      defmodule unquote(desc_name) do
        Module.register_attribute(__MODULE__, unquote(@desc_attr), persist: true)
        @protocol_ex_desc unquote(parsed_name)
        def spec, do: unquote(Macro.escape(spec))
      end
    end
  end



  @doc """
  Implement a protocol based on a matcher specification
  """
  defmacro defimplEx(impl_name, matcher, [{:for, for_name} | opts], [do: body]) do
    name = get_atom_name(for_name)
    name = __CALLER__.aliases[name] || name
    desc_name = get_desc_name(name)
    quote do
      require unquote(desc_name)
      ProtocolEx.defimplEx_do(unquote(Macro.escape(impl_name)), unquote(Macro.escape(matcher)), [for: unquote(Macro.escape(name))], [do: unquote(Macro.escape(body))], unquote(opts), __ENV__)
    end
  end

  @doc false
  def defimplEx_do(impl_name, matcher, [for: name], [do: body], opts, caller_env) do
    name = get_atom_name(name)
    desc_name = get_desc_name(name)
    impl_name = get_atom_name(impl_name)
    impl_name = get_impl_name(name, impl_name)
    impl_name = get_atom_name(impl_name)
    spec = desc_name.spec()

    impl_quoted = {:__block__, [],
      [ quote do
          def __matcher__, do: unquote(Macro.escape(matcher))
        end,
        quote do
          def __spec__, do: unquote(desc_name).spec()
        end,
        quote do
          Module.register_attribute(__MODULE__, :protocol_ex, persist: true)
        end,
        quote do
          @protocol_ex unquote(name)
        end,
        quote do
          Module.register_attribute(__MODULE__, :priority, persist: true)
        end,
        case opts[:inline] do
          nil -> quote do def __inlined__(_), do: nil end
          # :all -> quote do def __inlined__(_), do: true end
          funs when is_list(funs) ->
            funs
            |> Enum.map(fn {fun, arity} ->
              Macro.prewalk(body, [], fn
                ({:def, _, [{^fun, _, bindings}, _]} = ast, acc) when length(bindings) === arity ->
                  {ast, [ast | acc]}
                ({:def, _, [{:when, _, [{^fun, _, bindings}, _]}, _]} = ast, acc) when length(bindings) === arity ->
                  {ast, [ast | acc]}
                (ast, acc) ->
                  {ast, acc}
              end)
              |> case do
                {_body, ast} -> quote do def __inlined__({unquote(fun), unquote(arity)}), do: unquote(Macro.escape(ast)) end
              end
            end)
            |> Enum.reverse([quote do def __inlined__(_), do: nil end])
        end
      | List.wrap(body)
      ]}
    # impl_quoted |> Macro.to_string() |> IO.puts
    if Code.ensure_loaded?(impl_name) do
      :code.purge(impl_name)
    end
    Module.create(impl_name, impl_quoted, Macro.Env.location(caller_env))
    verify_valid_spec_on_module(name, spec, impl_name)
  end



  def consolidate_all(opts \\ []) do
    opts
    |> get_base_paths()
    |> Enum.flat_map(fn path ->
      path
      |> Path.join("*.beam")
      |> Path.wildcard()
      |> case do beam_paths ->
        beam_paths
        |> Enum.flat_map(fn path -> # Oh what I'd give for a monadic `do` right about now...  >.>
          case :beam_lib.chunks(path |> to_charlist(), [:attributes]) do
            {:ok, {_mod, chunks}} ->
              case get_in(chunks, [:attributes, @desc_attr]) do
                [proto] -> [proto]
                _ -> []
              end
            _err -> []
          end
        end)
        |> case do protocols ->
          beam_paths
          |> Enum.flat_map(fn path ->
            case :beam_lib.chunks(path |> to_charlist(), [:attributes]) do
              {:ok, {mod, chunks}} ->
                attributes = chunks[:attributes]
                case attributes[:protocol_ex] do
                  nil -> []
                  protos ->
                    protos
                    |> Enum.any?(&Enum.member?(protocols, &1))
                    |> if do
                      priority = hd(attributes[:priority] || [0])
                      data = {mod, priority, protos}
                      [data]
                    else
                      []
                    end
                end
              _err -> []
            end
          end)
          |> case do impls ->
            protocols
            |> Enum.map(fn proto_name ->
              consolidate(proto_name, impls: impls)
            end)
          end
        end
      end
    end)
  end

  @doc """
  Resolve a protocol into a final ready-to-use-module based on already-compiled names sorted by priority
  """
  def consolidate(proto_name, opts \\ []) do
    impls =
      case opts[:impls] do
        nil ->
          opts
          |> get_base_paths()
          |> Enum.flat_map(fn path ->
            path
            |> Path.join("*.beam")
            |> Path.wildcard()
          end)
          |> Enum.flat_map(fn path ->
            case :beam_lib.chunks(path |> to_charlist(), [:attributes]) do
              {:ok, {mod, chunks}} ->
                attributes = chunks[:attributes]
                case attributes[:protocol_ex] do
                  nil -> []
                  protos ->
                    if Enum.member?(protos, proto_name) do
                      priority = hd(attributes[:priority] || [0])
                      data = {mod, priority, protos}
                      [data]
                    else
                      []
                    end
                end
                _err -> []
            end
          end)
        impls -> Enum.filter(impls, &(Enum.member?(elem(&1, 2), proto_name)))
      end
      |> Enum.sort_by(fn {name, prio, _} -> {prio, to_string(name)} end, &>=/2) # Sort by priority, then by binary name
      |> Enum.map(&elem(&1, 0))
    proto_desc = Module.concat(proto_name, @desc_name)
    spec =
      case proto_desc.spec() do
        %Spec{} = spec -> spec
        err -> throw {:invalid_spec, err}
      end

    impl_quoted = {:__block__, [],
      [ quote do def __protocolEx__, do: unquote(Macro.escape(spec)) end
      | Enum.flat_map(:lists.reverse(spec.callbacks), &load_abstract_from_impls(proto_name, &1, impls))
      ]}
    # impl_quoted |> Macro.to_string() |> IO.puts
    if Code.ensure_loaded?(proto_name) do
      :code.purge(proto_name)
    end
    Module.create(proto_name, impl_quoted, Macro.Env.location(__ENV__))
    proto_name
  end

  @doc """
  Resolve a protocol into a final ready-to-use-module based on implementation names

  If priority_sorted is true then it sorts based on the impl priority, else it uses the defined order
  """
  defmacro resolveProtocolEx(orig_name, impls, priority_sorted \\ false) when is_list(impls) do
    name = get_atom_name(orig_name)
    name = __CALLER__.aliases[name] || name
    desc_name = get_desc_name(name)
    impls = Enum.map(impls, &get_atom_name/1)
    impls = Enum.map(impls, &get_atom_name_with(name, &1))
    impls = Enum.map(impls, &get_atom_name/1)
    impls = if(priority_sorted, do: Enum.sort_by(impls, &(&1.module_info()[:attributes][:priority] || 0), &>=/2), else: impls)
    requireds = Enum.map([desc_name | impls], fn req ->
      {:require, [], [req]}
      # quote do
      #   require unquote(req)
      # end
    end)
    quote do
      __silence_alias_warnings__ = unquote(orig_name)
      unquote_splicing(requireds)
      ProtocolEx.resolveProtocolEx_do(unquote(name), unquote(impls))
    end
  end

  @doc false
  defmacro resolveProtocolEx_do(name, impls) when is_list(impls) do
    name = get_atom_name(name)
    desc_name = get_desc_name(name)
    spec = desc_name.spec()
    impl_quoted = {:__block__, [],
      [ quote do def __protocolEx__, do: unquote(Macro.escape(spec)) end
      | Enum.flat_map(:lists.reverse(spec.callbacks), &load_abstract_from_impls(name, &1, impls))
      ]}
    # impl_quoted |> Macro.to_string() |> IO.puts
    if Code.ensure_loaded?(name) do
      :code.purge(name)
    end
    Module.create(name, impl_quoted, Macro.Env.location(__CALLER__))
    :ok
  end


  defp get_base_paths(opts) do
    case opts[:ebin_root] do
      nil -> :code.get_path()
      paths -> List.wrap(paths)
    end
  end

  defp get_protocolex_modules(paths)

  defp get_modules_from_beam_with_attribute_filter(paths, attribute, value) do
    List.wrap(paths)
    |> Enum.flat_map(fn path ->
      path
      |> Path.join("*.beam")
      |> Path.wildcard()
    end)
    |> throw
  end


  defp get_impls_from_compiled(base_name) do
    throw {:test, base_name}
  end

  defp beam_protocol(protocol) do
    chunk_ids = [:abstract_code, :attributes, :compile_info, 'ExDc']
    opts = [:allow_missing_chunks]
    case :beam_lib.chunks(beam_file(protocol), chunk_ids, opts) do
      {:ok, {^protocol, [{:abstract_code, {_raw, abstract_code}},
                         {:attributes, attributes},
                         {:compile_info, compile_info},
                         {'ExDc', docs}]}} ->
        case attributes[:protocol] do
          [fallback_to_any: any] ->
            {:ok, {protocol, any, abstract_code}, {compile_info, docs}}
          _ ->
            {:error, :not_a_protocol}
        end
      _ ->
        {:error, :no_beam_info}
    end
  end

  defp beam_file(module) when is_atom(module) do
    case :code.which(module) do
      atom when is_atom(atom) -> module
      file -> file
    end
  end



  defp get_atom_name(name) when is_atom(name), do: name
  defp get_atom_name({:__aliases__, _, names}) when is_list(names), do: Module.concat(names)

  defp get_atom_name_with(name, at_end) when is_atom(name) and is_atom(at_end), do: {:__aliases__, [alias: false], [name, at_end]}
  defp get_atom_name_with({:__aliases__, meta, names}, at_end) when is_list(names) and is_atom(at_end), do: {:__aliases__, meta, names ++ [at_end]}

  defp get_desc_name(name) when is_atom(name), do: Module.concat([name, @desc_name])

  defp get_impl_name(name, impl_name) when is_atom(name), do: Module.concat(name, impl_name)


  defp decompose_spec(returned \\ %Spec{}, body)
  defp decompose_spec(returned, {:__block__, _, body}), do: decompose_spec(returned, body)
  defp decompose_spec(returned, []), do: returned
  defp decompose_spec(returned, [elem | rest]), do: decompose_spec(decompose_spec_element(returned, elem), rest)
  defp decompose_spec(returned, body), do: decompose_spec(returned, [body])


  defp decompose_spec_element(returned, elem)
  # defp decompose_spec_element(returned, {:def, meta, [{name, name_meta, noargs}]}) when is_atom(noargs), do: decompose_spec_element(returned, {:def, meta, [{name, name_meta, []}]})
  defp decompose_spec_element(returned, {:def, _meta, [head]} = elem) do
    {name, args_length} = decompose_spec_head(head)
    callbacks = [{name, args_length, elem} | returned.callbacks]
    %{returned | callbacks: callbacks}
  end
  defp decompose_spec_element(returned, {:def, meta, [head, _body]}=elem) do
    {name, args_length} = decompose_spec_head(head)
    head = {:def, meta, [head]}
    callbacks = [{name, args_length, head, elem} | returned.callbacks]
    %{returned | callbacks: callbacks}
  end
  defp decompose_spec_element(_returned, unhandled_elem), do: raise %InvalidProtocolSpecification{ast: unhandled_elem}


  defp decompose_spec_head(head)
  defp decompose_spec_head({:when, _when_meta, [head, _guard]}) do
    decompose_spec_head(head)
  end
  defp decompose_spec_head({name, _name_meta, args}) when is_atom(name) and is_list(args) do
    {name, length(args)}
  end
  defp decompose_spec_head(head), do: raise %InvalidProtocolSpecification{ast: head}


  defp verify_valid_spec(spec) do
    callbacks = Enum.uniq_by(spec.callbacks, fn
      {name, arity, _elem} -> {name, arity}
      {name, arity, _elem_head, _elem} -> {name, arity}
    end)
    if length(spec.callbacks) !== length(callbacks) do
      [{name, arity, _elem}|_] = spec.callbacks -- callbacks
      raise %DuplicateSpecification{name: name, arity: arity}
    end
    spec
  end


  defp verify_valid_spec_on_module(proto, spec, module) do
    spec.callbacks
    |> Enum.map(fn
      {name, arity, _} ->
        if :erlang.function_exported(module, name, arity) do
          :ok
        else
          raise  %MissingRequiredProtocolDefinition{proto: proto, impl: module, name: name, arity: arity}
        end
      {_name, _arity, _, _} -> :ok
    end)
    :ok
  end


  defp load_abstract_from_impls(pname, abstract, impls, returning \\ [])
  defp load_abstract_from_impls(pname, abstract, [], returning) do
    case abstract do
      {name, arity, ast_head} ->
        args = get_args_from_head(ast_head)
        first_arg = hd(args)
        rest_args = tl(args)
        rest_args =
          Enum.map(rest_args, fn arg ->
            quote do
              _ = unquote(arg)
            end
          end)
        body =
          {:raise, [context: Elixir, import: Kernel],
           [{:%, [],
             [{:__aliases__, [alias: false], [:ProtocolEx, :UnimplementedProtocolEx]},
              {:%{}, [],
               [proto: pname, name: name, arity: arity, value: first_arg]
               }]}]}
        body =
          quote do
            unquote_splicing(rest_args)
            unquote(body)
          end
        catch_all = append_body_to_head(ast_head, body)
        :lists.reverse(returning, [catch_all])
      {_name, _arity, _ast_head, ast_fallback}  ->
        :lists.reverse(returning, [ast_fallback])
    end
  end
  defp load_abstract_from_impls(pname, abstract, [impl | impls], returning) do
    case abstract do
      {name, arity, ast_head} ->
        if Enum.any?(impl.module_info()[:exports], fn {^name, ^arity} -> true; _ -> false end) do
          {name, ast_head}
        else
          raise %MissingRequiredProtocolDefinition{proto: pname, impl: impl, name: name, arity: arity}
        end
      {name, arity, ast_head, _ast_fallback}  ->
        if Enum.any?(impl.module_info()[:exports], fn {^name, ^arity} -> true; _ -> false end) do
          {name, ast_head}
        else
          :skip
        end
    end
    |> case do
      :skip -> load_abstract_from_impls(pname, abstract, impls, returning)
      {name, ast_head} ->
          matchers = List.wrap(impl.__matcher__())
          args = get_args_from_head(ast_head)
          arity = length(args)
          if :erlang.function_exported(impl, :__inlined__, 1) do
            impl.__inlined__({name, arity})
          else
            nil
          end
          |> case do
            nil ->
              body = build_body_call_with_args(impl, name, args)
              head_args = bind_matcher_to_args(matchers, args)
              ast_head = replace_head_args_with(ast_head, head_args)
              guard = get_guards_from_matchers(matchers)
              ast_head = if(guard == true, do: ast_head, else: add_guard_to_head(ast_head, guard))
              ast = append_body_to_head(ast_head, body)
              load_abstract_from_impls(pname, abstract, impls, [ast | returning])
            inlined_impls when is_list(inlined_impls) ->
              guard = get_guards_from_matchers(matchers)
              inlined_impls =
                if(guard == true) do
                  inlined_impls = Enum.map(inlined_impls, &add_guard_to_head(&1, guard))
                  load_abstract_from_impls(pname, abstract, impls, inlined_impls ++ returning)
                else
                  load_abstract_from_impls(pname, abstract, impls, inlined_impls ++ returning)
                end
          end
    end
  end

  defp get_args_from_head(ast_head)
  defp get_args_from_head({:def, _meta, [{:when, _when_meta, [{_name, _name_meta, args}, _guard]}]}) do
    # Enum.map(List.wrap(args), fn
    #   {name, _, scope} = ast when is_atom(name) and is_atom(scope) -> ast
    #   end)
    args
  end
  defp get_args_from_head({:def, _meta, [{_name, _name_meta, args}]}) do
    # Enum.map(List.wrap(args), fn
    #   {name, _, scope} = ast when is_atom(name) and is_atom(scope) -> ast
    #   end)
    args
  end

  defp bind_matcher_to_args(matcher, args, returned \\ [])
  defp bind_matcher_to_args(_matcher, [], returned), do: :lists.reverse(returned)
  defp bind_matcher_to_args([], args, returned), do: :lists.reverse(returned, args)
  defp bind_matcher_to_args([{:when, _when_meta, [binding_ast, _when_call]} | matchers], [arg_ast | args], returned) do
    arg = {:=, [], [binding_ast, arg_ast]}
    bind_matcher_to_args(matchers, args, [arg | returned])
  end
  defp bind_matcher_to_args([binding_ast | matchers], [arg_ast | args], returned) do
    arg = {:=, [], [binding_ast, arg_ast]}
    bind_matcher_to_args(matchers, args, [arg | returned])
  end

  defp replace_head_args_with(ast_head, head_args)
  defp replace_head_args_with({:def, meta, [{:when, when_meta, [{name, name_meta, _args}, guards]} | rest]}, head_args) do
    {:def, meta, [{:when, when_meta, [{name, name_meta, head_args}, guards]} | rest]}
  end
  defp replace_head_args_with({:def, meta, [{name, name_meta, _args} | rest]}, head_args) do
    {:def, meta, [{name, name_meta, head_args} | rest]}
  end

  defp get_guards_from_matchers(matchers, returned \\ [])
  defp get_guards_from_matchers([], []), do: true
  defp get_guards_from_matchers([], returned), do: Enum.reduce(:lists.reverse(returned), fn(ast, acc) -> {:and, [], [ast, acc]} end)
  defp get_guards_from_matchers([{:when, _when_meta, [_bindings, guard]} | matchers], returned) do
    get_guards_from_matchers(matchers, [guard | returned])
  end
  defp get_guards_from_matchers([_when_ast | matchers], returned) do
    get_guards_from_matchers(matchers, returned)
  end

  defp add_guard_to_head(ast_head, guard)
  defp add_guard_to_head({:def, meta, [{:when, when_meta, [head, old_guard]} | rest]}, guard) do
    {:def, meta, [
      {:when, when_meta, [head, {:and, [], [old_guard, guard]}]}
      | rest
      ]}
  end
  defp add_guard_to_head({:def, meta, [head | rest]}, guard) do
    {:def, meta, [
      {:when, [], [head, guard]}
      | rest
      ]}
  end

  defp build_body_call_with_args(module, name, args) do
    quote do
      unquote(module).unquote(name)(unquote_splicing(args))
    end
  end

  defp append_body_to_head(ast_head, body)
  defp append_body_to_head({:def, meta, args}, body), do: {:def, meta, args++[[do: body]]}
end

if Mix.env() === :test do
  # MyDecimal for Numbers
  defimpl Numbers.Protocols.Addition, for: Tuple do
    def add({MyDecimal, _s0, :sNaN, _e0}, {MyDecimal, _s1, _c1, _e1}), do: throw :error
    def add({MyDecimal, _s0, _c0, _e0}, {MyDecimal, _s1, :sNaN, _e1}), do: throw :error
    def add({MyDecimal, _s0, :qNaN, _e0} = d0, {MyDecimal, _s1, _c1, _e1}), do: d0
    def add({MyDecimal, _s0, _c0, _e0}, {MyDecimal, _s1, :qNaN, _e1} = d1), do: d1
    def add({MyDecimal, s0, :inf, e0} = d0, {MyDecimal, s0, :inf, e1} = d1), do: if(e0 > e1, do: d0, else: d1)
    def add({MyDecimal, _s0, :inf, _e0}, {MyDecimal, _s1, :inf, _e1}), do: throw :error
    def add({MyDecimal, _s0, :inf, _e0} = d0, {MyDecimal, _s1, _c1, _e1}), do: d0
    def add({MyDecimal, _s0, _c0, _e0}, {MyDecimal, _s1, :inf, _e1} = d1), do: d1
    def add({MyDecimal, s0, c0, e0}, {MyDecimal, s1, c1, e1}) do
      {c0, c1} =
        cond do
          e0 === e1 -> {c0, c1}
          e0 > e1 -> {c0 * pow10(e0 - e1), c1}
          true -> {c0, c1 * pow10(e1 - e0)}
        end
      c = s0 * c0 + s1 * c1
      e = Kernel.min(e0, e1)
      s =
        cond do
          c > 0 -> 1
          c < 0 -> -1
          s0 == -1 and s1 == -1 -> -1
          # s0 != s1 and get_context().rounding == :floor -> -1
          true -> 1
        end
      {s, Kernel.abs(c), e}
    end
    def mult({MyDecimal, s0, c0, e0}, {MyDecimal, s1, c1, e1}) do
      s = s0 * s1
      {s, c0 * c1, e0 + e1}
    end
    def add_id(_num), do: {MyDecimal, 1, 0, 0}

    _pow10_max = Enum.reduce 0..104, 1, fn int, acc ->
      def pow10(unquote(int)), do: unquote(acc)
      def base10?(unquote(acc)), do: true
      acc * 10
    end
    def pow10(num) when num > 104, do: pow10(104) * pow10(num - 104)
  end

  defimpl Numbers.Protocols.Multiplication, for: Tuple do
    def mult({MyDecimal, _s0, :sNaN, _e0}, {MyDecimal, _s1, _c1, _e1}), do: throw :error
    def mult({MyDecimal, _s0, _c0, _e0}, {MyDecimal, _s1, :sNaN, _e1}), do: throw :error
    def mult({MyDecimal, _s0, :qNaN, _e0}, {MyDecimal, _s1, _c1, _e1}), do: throw :error
    def mult({MyDecimal, _s0, _c0, _e0}, {MyDecimal, _s1, :qNaN, _e1}), do: throw :error
    def mult({MyDecimal, _s0, 0, _e0}, {MyDecimal, _s1, :inf, _e1}), do: throw :error
    def mult({MyDecimal, _s0, :inf, _e0}, {MyDecimal, _s1, 0, _e1}), do: throw :error
    def mult({MyDecimal, s0, :inf, e0}, {MyDecimal, s1, _, e1}) do
      s = s0 * s1
      {s, :inf, e0+e1}
    end
    def mult({MyDecimal, s0, _, e0}, {MyDecimal, s1, :inf, e1}) do
      s = s0 * s1
      {s, :inf, e0+e1}
    end
    def mult({MyDecimal, s0, c0, e0}, {MyDecimal, s1, c1, e1}) do
      s = s0 * s1
      {s, c0 * c1, e0 + e1}
    end
    def mult_id(_num), do: {MyDecimal, 1, 1, 0}
  end
end
