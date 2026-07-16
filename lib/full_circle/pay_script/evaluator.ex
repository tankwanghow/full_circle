defmodule FullCircle.PayScript.Evaluator do
  @moduledoc false

  alias FullCircle.PayScript.Error

  @ytd_keys %{"code" => :code, "type" => :type, "name" => :name}

  def eval_script(bindings, context, env) do
    bindings
    |> Enum.reduce_while({:ok, context}, fn {name, expr}, {:ok, vars} ->
      case eval(expr, vars, env) do
        {:ok, val} -> {:cont, {:ok, Map.put(vars, name, val)}}
        {:error, %Error{} = e} -> {:halt, {:error, %{e | binding: e.binding || name}}}
      end
    end)
    |> case do
      {:ok, vars} -> {:ok, Map.fetch!(vars, "result")}
      err -> err
    end
  end

  def eval({:num, n}, _vars, _env), do: {:ok, n}
  def eval({:str, s}, _vars, _env), do: {:ok, s}
  def eval({:bool, b}, _vars, _env), do: {:ok, b}

  def eval({:list, items}, vars, env) do
    Enum.reduce_while(items, {:ok, []}, fn item, {:ok, acc} ->
      case eval(item, vars, env) do
        {:ok, v} -> {:cont, {:ok, [v | acc]}}
        err -> {:halt, err}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      err -> err
    end
  end

  def eval({:var, name}, vars, _env) do
    case Map.fetch(vars, name) do
      {:ok, v} -> {:ok, v}
      :error -> {:error, %Error{message: "unknown identifier '#{name}'"}}
    end
  end

  def eval({:neg, e}, vars, env) do
    with {:ok, v} <- eval_num(e, vars, env), do: {:ok, -v}
  end

  def eval({:not, e}, vars, env) do
    with {:ok, v} <- eval(e, vars, env) do
      if is_boolean(v), do: {:ok, not v}, else: type_error("not", v)
    end
  end

  def eval({:if, c, t, e}, vars, env) do
    with {:ok, cond_v} <- eval(c, vars, env) do
      case cond_v do
        true -> eval(t, vars, env)
        false -> eval(e, vars, env)
        other -> type_error("if condition", other)
      end
    end
  end

  def eval({:binop, op, l, r}, vars, env) when op in [:and, :or],
    do: eval_logic(op, l, r, vars, env)

  def eval({:binop, op, l, r}, vars, env) do
    with {:ok, lv} <- eval(l, vars, env),
         {:ok, rv} <- eval(r, vars, env),
         do: apply_binop(op, lv, rv)
  end

  def eval({:call, name, args}, vars, env), do: eval_call(name, args, vars, env)

  def eval({:kw, key, _}, _vars, _env),
    do: {:error, %Error{message: "unexpected keyword argument '#{key}:'"}}

  defp eval_logic(op, l, r, vars, env) do
    with {:ok, lv} <- eval(l, vars, env) do
      case {op, lv} do
        {:and, false} ->
          {:ok, false}

        {:or, true} ->
          {:ok, true}

        {_, b} when is_boolean(b) ->
          with {:ok, rv} <- eval(r, vars, env) do
            if is_boolean(rv), do: {:ok, rv}, else: type_error("'#{op}'", rv)
          end

        {_, other} ->
          type_error("'#{op}'", other)
      end
    end
  end

  defp apply_binop(:add, l, r) when is_number(l) and is_number(r), do: {:ok, l + r}
  defp apply_binop(:sub, l, r) when is_number(l) and is_number(r), do: {:ok, l - r}
  defp apply_binop(:mul, l, r) when is_number(l) and is_number(r), do: {:ok, l * r}

  defp apply_binop(:div, l, r) when is_number(l) and is_number(r) do
    if r == 0 do
      {:error, %Error{message: "division by zero"}}
    else
      {:ok, l / r}
    end
  end

  defp apply_binop(:eq, l, r), do: compare_eq(l, r, & &1)
  defp apply_binop(:neq, l, r), do: compare_eq(l, r, &(not &1))

  defp apply_binop(op, l, r)
       when op in [:gt, :gte, :lt, :lte] and is_number(l) and is_number(r) do
    result =
      case op do
        :gt -> l > r
        :gte -> l >= r
        :lt -> l < r
        :lte -> l <= r
      end

    {:ok, result}
  end

  defp apply_binop(op, l, r) do
    {:error,
     %Error{
       message: "cannot apply '#{op_text(op)}' to #{value_label(l)} and #{value_label(r)}"
     }}
  end

  defp compare_eq(l, r, f) when is_number(l) and is_number(r), do: {:ok, f.(l == r)}
  defp compare_eq(l, r, f) when is_binary(l) and is_binary(r), do: {:ok, f.(l == r)}
  defp compare_eq(l, r, f) when is_boolean(l) and is_boolean(r), do: {:ok, f.(l == r)}

  defp compare_eq(l, r, _f),
    do: {:error, %Error{message: "cannot compare #{value_label(l)} with #{value_label(r)}"}}

  defp eval_call("min", [a, b], vars, env), do: num2(a, b, vars, env, &min/2)
  defp eval_call("max", [a, b], vars, env), do: num2(a, b, vars, env, &max/2)
  defp eval_call("ceil", [a], vars, env), do: num1(a, vars, env, &Float.ceil/1)
  defp eval_call("floor", [a], vars, env), do: num1(a, vars, env, &Float.floor/1)
  defp eval_call("abs", [a], vars, env), do: num1(a, vars, env, &abs/1)

  defp eval_call("round", [a, b], vars, env) do
    with {:ok, x} <- eval_num(a, vars, env),
         {:ok, n} <- eval_num(b, vars, env),
         do: {:ok, Float.round(x, trunc(n))}
  end

  defp eval_call("upper", [a], vars, env), do: str1(a, vars, env, &String.upcase/1)
  defp eval_call("lower", [a], vars, env), do: str1(a, vars, env, &String.downcase/1)
  defp eval_call("trim", [a], vars, env), do: str1(a, vars, env, &String.trim/1)

  defp eval_call("replace", [s, from, to], vars, env) do
    with {:ok, str} <- eval_str(s, vars, env),
         {:ok, from_str} <- eval_str(from, vars, env),
         {:ok, to_str} <- eval_str(to, vars, env),
         do: {:ok, String.replace(str, from_str, to_str)}
  end

  defp eval_call("lookup", [t, v, c], vars, env) do
    with {:ok, table} <- eval_str(t, vars, env),
         {:ok, value} <- eval_num(v, vars, env),
         {:ok, column} <- eval_str(c, vars, env),
         do: env_call(env, :lookup, [table, value, column])
  end

  defp eval_call("ytd_sum", [{:kw, key, e}], vars, env) when is_map_key(@ytd_keys, key) do
    with {:ok, val} <- eval(e, vars, env),
         {:ok, keys} <- string_list(key, val),
         do: env_call(env, :ytd_sum, [@ytd_keys[key], keys])
  end

  defp eval_call("ytd_sum", _args, _vars, _env) do
    {:error, %Error{message: "ytd_sum expects a single 'code:', 'type:' or 'name:' argument"}}
  end

  defp eval_call("calc", [e], vars, env) do
    with {:ok, code} <- eval_str(e, vars, env), do: env_call(env, :calc, [code])
  end

  defp eval_call(name, args, _vars, _env),
    do: {:error, %Error{message: "unknown function #{name}/#{length(args)}"}}

  defp num1(a, vars, env, f) do
    with {:ok, x} <- eval_num(a, vars, env), do: {:ok, f.(x)}
  end

  defp num2(a, b, vars, env, f) do
    with {:ok, x} <- eval_num(a, vars, env),
         {:ok, y} <- eval_num(b, vars, env),
         do: {:ok, f.(x, y)}
  end

  defp str1(a, vars, env, f) do
    with {:ok, x} <- eval_str(a, vars, env), do: {:ok, f.(x)}
  end

  defp eval_num(e, vars, env) do
    with {:ok, v} <- eval(e, vars, env) do
      if is_number(v) do
        {:ok, v * 1.0}
      else
        {:error, %Error{message: "expected a number, got #{value_label(v)}"}}
      end
    end
  end

  defp eval_str(e, vars, env) do
    with {:ok, v} <- eval(e, vars, env) do
      if is_binary(v) do
        {:ok, v}
      else
        {:error, %Error{message: "expected a string, got #{value_label(v)}"}}
      end
    end
  end

  defp string_list(_key, v) when is_binary(v), do: {:ok, [v]}

  defp string_list(key, v) when is_list(v) do
    if v != [] and Enum.all?(v, &is_binary/1) do
      {:ok, v}
    else
      {:error, %Error{message: "ytd_sum #{key}: must be a string or list of strings"}}
    end
  end

  defp string_list(key, _v),
    do: {:error, %Error{message: "ytd_sum #{key}: must be a string or list of strings"}}

  defp env_call(nil, fun, _args),
    do: {:error, %Error{message: "#{fun} is not available in this context"}}

  defp env_call({mod, state}, fun, args) do
    case apply(mod, fun, [state | args]) do
      {:ok, v} when is_number(v) -> {:ok, v * 1.0}
      {:ok, v} when is_binary(v) -> {:ok, v}
      {:ok, v} when is_boolean(v) -> {:ok, v}
      {:error, msg} when is_binary(msg) -> {:error, %Error{message: msg}}
      {:error, %Error{} = e} -> {:error, e}
    end
  end

  defp type_error(what, v),
    do: {:error, %Error{message: "#{what} expects a boolean, got #{value_label(v)}"}}

  defp value_label(v) when is_number(v), do: "number #{v}"
  defp value_label(v) when is_binary(v), do: "string #{inspect(v)}"
  defp value_label(v) when is_boolean(v), do: "boolean #{v}"
  defp value_label(v) when is_list(v), do: "a list"

  defp op_text(:add), do: "+"
  defp op_text(:sub), do: "-"
  defp op_text(:mul), do: "*"
  defp op_text(:div), do: "/"
  defp op_text(op), do: to_string(op)
end
