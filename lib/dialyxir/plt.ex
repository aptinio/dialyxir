# Credits: this code was originally part of the `dialyze` task
# Copyright by James Fish
# https://github.com/fishcakez/dialyze

defmodule Dialyxir.Plt do

  def plts_list(deps) do
    elixir_apps = [:elixir]
    erlang_apps = [:erts, :kernel, :stdlib, :crypto]
    [{deps_plt(), deps ++ elixir_apps ++ erlang_apps},
     {elixir_plt(), elixir_apps},
     {erlang_plt(), erlang_apps}]
  end

  def erlang_plt(), do: global_plt("erlang-" <> otp_vsn())

  defp otp_vsn() do
    major = :erlang.system_info(:otp_release)
    vsn_file = Path.join([:code.root_dir(), "releases", major, "OTP_VERSION"])
    try do
      {:ok, contents} = File.read(vsn_file)
      String.split(contents, "\n", trim: true)
    else
      [full] ->
        full
      _ ->
        major
    catch
      :error, _ ->
        major
    end
  end

  def elixir_plt() do
    global_plt("erlang-#{otp_vsn()}_elixir-#{System.version()}")
  end

  def deps_plt do
    name = "erlang-#{otp_vsn()}_elixir-#{System.version()}_deps-#{build_env()}"
    local_plt(name)
  end

  defp build_env() do
    config = Mix.Project.config()
    case Keyword.fetch!(config, :build_per_environment) do
      true -> Atom.to_string(Mix.env())
      false -> "shared"
    end
  end

  defp global_plt(name) do
    Path.join(Mix.Utils.mix_home(), "dialyxir_" <> name <> ".plt")
  end

  defp local_plt(name) do
    Path.join(Mix.Project.build_path(), "dialyxir_" <> name <> ".plt")
  end

  def check(plts) do
    info("Finding suitable PLTs")
    find_plts(plts, [])
  end

  defp find_plts([{plt, apps} | plts], acc) do
    case plt_files(plt) do
      nil ->
        find_plts(plts, [{plt, apps, nil} | acc])
      beams ->
        apps_rest = Enum.flat_map(plts, fn({_plt2, apps2}) -> apps2 end)
        apps = Enum.uniq(apps ++ apps_rest)
        check_plts([{plt, apps, beams} | acc])
    end
  end
  defp find_plts([], acc) do
    check_plts(acc)
  end

  defp check_plts(plts) do
    {last_plt, beams, _cache} = Enum.reduce(plts, {nil, HashSet.new(), %{}},
      fn({plt, apps, beams}, acc) ->
        check_plt(plt, apps, beams, acc)
      end)
    {last_plt, beams}
  end

  defp check_plt(plt, apps, old_beams, {prev_plt, prev_beams, prev_cache}) do
    info("Finding applications for #{Path.basename(plt)}")
    cache = resolve_apps(apps, prev_cache)
    mods = cache_mod_diff(cache, prev_cache)
    info("Finding modules for #{Path.basename(plt)}")
    beams = resolve_modules(mods, prev_beams)
    check_beams(plt, beams, old_beams, prev_plt)
    {plt, beams, cache}
  end

  defp cache_mod_diff(new, old) do
    Enum.flat_map(new,
      fn({app, {mods, _deps}}) ->
        case Map.has_key?(old, app) do
          true -> []
          false -> mods
        end
      end)
  end

  defp resolve_apps(apps, cache) do
    apps
    |> Enum.uniq()
    |> Enum.filter_map(&(not Map.has_key?(cache, &1)), &app_info/1)
    |> Enum.into(cache)
  end

  defp app_info(app) do
    app_file = Atom.to_char_list(app) ++ '.app'
    case :code.where_is_file(app_file) do
      :non_existing ->
        error("Unknown application #{inspect(app)}")
        {app, {[], []}}
      app_file ->
        Path.expand(app_file)
        |> read_app_info(app)
    end
  end

  defp read_app_info(app_file, app) do
    case :file.consult(app_file) do
      {:ok, [{:application, ^app, info}]} ->
        parse_app_info(info, app)
      {:error, reason} ->
        Mix.raise "Could not read #{app_file}: #{:file.format_error(reason)}"
    end
  end

  defp parse_app_info(info, app) do
    mods = Keyword.get(info, :modules, [])
    apps = Keyword.get(info, :applications, [])
    inc_apps = Keyword.get(info, :included_applications, [])
    runtime_deps = get_runtime_deps(info)
    {app, {mods, runtime_deps ++ inc_apps ++ apps}}
  end

  defp get_runtime_deps(info) do
    Keyword.get(info, :runtime_dependencies, [])
    |> Enum.map(&parse_runtime_dep/1)
  end

  defp parse_runtime_dep(runtime_dep) do
    runtime_dep = IO.chardata_to_string(runtime_dep)
    regex =  ~r/^(.+)\-\d+(?|\.\d+)*$/
    [app] = Regex.run(regex, runtime_dep, [capture: :all_but_first])
    String.to_atom(app)
  end

  defp resolve_modules(modules, beams) do
    Enum.reduce(modules, beams, &resolve_module/2)
  end

  defp resolve_module(module, beams) do
    beam = Atom.to_char_list(module) ++ '.beam'
    case :code.where_is_file(beam) do
      path when is_list(path) ->
        path = Path.expand(path)
        HashSet.put(beams, path)
      :non_existing ->
        error("Unknown module #{inspect(module)}")
        beams
    end
  end

  defp check_beams(plt, beams, nil, prev_plt) do
    plt_ensure(plt, prev_plt)
    case plt_files(plt) do
      nil ->
        Mix.raise("Could not open #{plt}: #{:file.format_error(:enoent)}")
      old_beams ->
        check_beams(plt, beams, old_beams)
    end
  end

  defp check_beams(plt, beams, old_beams, _prev_plt) do
    check_beams(plt, beams, old_beams)
  end

  defp check_beams(plt, beams, old_beams) do
    remove = HashSet.difference(old_beams, beams)
    plt_remove(plt, remove)
    check = HashSet.intersection(beams, old_beams)
    plt_check(plt, check)
    add = HashSet.difference(beams, old_beams)
    plt_add(plt, add)
  end

  defp plt_ensure(plt, nil), do: plt_new(plt)
  defp plt_ensure(plt, prev_plt), do: plt_copy(prev_plt, plt)

  defp plt_new(plt) do
    info("Creating #{Path.basename(plt)}")
    plt = erl_path(plt)
    _ = plt_run([analysis_type: :plt_build, output_plt: plt,
      apps: [:erts]])
    :ok
  end

  defp plt_copy(plt, new_plt) do
    info("Copying #{Path.basename(plt)} to #{Path.basename(new_plt)}")
    File.cp!(plt, new_plt)
  end

  defp plt_add(plt, files) do
    case HashSet.size(files) do
      0 ->
        :ok
      n ->
        (Mix.shell()).info("Adding #{n} modules to #{Path.basename(plt)}")
        plt = erl_path(plt)
        files = erl_files(files)
        _ = plt_run([analysis_type: :plt_add, init_plt: plt,
          files: files])
        :ok
    end
  end

  defp plt_remove(plt, files) do
    case HashSet.size(files) do
      0 ->
        :ok
      n ->
        info("Removing #{n} modules from #{Path.basename(plt)}")
        plt = erl_path(plt)
        files = erl_files(files)
        _ = plt_run([analysis_type: :plt_remove, init_plt: plt,
          files: files])
        :ok
    end
  end

  defp plt_check(plt, files) do
    case HashSet.size(files) do
      0 ->
        :ok
      n ->
        (Mix.shell()).info("Checking #{n} modules in #{Path.basename(plt)}")
        plt = erl_path(plt)
        _ = plt_run([analysis_type: :plt_check, init_plt: plt])
        :ok
    end
  end

  defp plt_run(opts) do
    :dialyzer.run([check_plt: false] ++ opts)
  end

  defp plt_info(plt) do
    erl_path(plt)
    |> :dialyzer.plt_info()
  end

  defp erl_files(files) do
    Enum.reduce(files, [], &[erl_path(&1)|&2])
  end

  defp erl_path(path) do
    encoding = :file.native_name_encoding()
    :unicode.characters_to_list(path, encoding)
  end

  defp plt_files(plt) do
    info("Looking up modules in #{Path.basename(plt)}")
    case plt_info(plt) do
      {:ok, info} ->
        Keyword.fetch!(info, :files)
        |> Enum.reduce(HashSet.new(), &HashSet.put(&2, Path.expand(&1)))
      {:error, :no_such_file} ->
        nil
      {:error, reason} ->
        Mix.raise("Could not open #{plt}: #{:file.format_error(reason)}")
    end
  end

  defp info(msg), do: apply(Mix.shell(), :info, [msg])

  defp error(msg), do: apply(Mix.shell(), :error, [msg])

end
