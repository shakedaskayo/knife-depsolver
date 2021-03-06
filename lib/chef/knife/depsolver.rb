require 'chef/knife'
require 'digest'

module DepSelector
  class VersionConstraint
    attr_reader :missing_patch_level
  end
end

class Chef
  class Knife
    class Depsolver < Knife
      deps do
      end

      banner 'knife depsolver RUN_LIST'

      option :node,
             short: '-n',
             long: '--node NAME',
             description: 'Use the run list from a given node'

      option :timeout,
             short: '-t',
             long: '--timeout SECONDS',
             description: 'Set the local depsolver timeout. Only valid when using the --env-constraints and --universe options'

      option :capture,
             long: '--capture',
             description: 'Save the expanded run list, environment cookbook constraints and cookbook universe to files for local depsolving'

      option :env_constraints,
             long: '--env-constraints FILENAME',
             description: 'Use the environment cookbook constraints from FILENAME. REQUIRED when using the local depsolver.'

      option :universe,
             long: '--universe FILENAME',
             description: 'Use the cookbook universe from FILENAME. REQUIRED when using the local depsolver.'

      option :expanded_run_list,
             long: '--expanded-run-list FILENAME',
             description: 'Use the expanded run list from FILENAME. REQUIRED when using the local depsolver.'

      option :csv_universe_to_json,
             long: '--csv-universe-to-json FILENAME',
             description: 'Convert a CSV cookbook universe, FILENAME, to JSON.'

      option :filter_universe,
           long: '--filter-universe',
           description: 'Filter the cookbook universe by environment cookbook version constraints and an optional run list.'

      option :version_pin_cookbooks,
           long: '--version-pin-cookbooks FILENAME',
           description: 'Print the cookbooks and dependency data that would be sent to the depsolver.'

      def run
        begin
          DepSelector::Debug.log.level = Logger::INFO if defined?(DepSelector::Debug)
          use_local_depsolver = config[:universe] ? true : false
          if use_local_depsolver
            unless name_args.empty?
              puts "ERROR: Setting a run list on the command line is not compatible with the --universe option"
              exit!
            end
            if config[:node]
              puts "ERROR: The --node option is not compatible with the --universe option"
              exit!
            end
            if config[:environment]
              puts "ERROR: The --environment option is not compatible with the --universe option"
              exit!
            end
            if config[:capture]
              puts "ERROR: The --capture option is not compatible with the --universe option"
              exit!
            end
          else
            if (config[:env_constraints] || config[:expanded_run_list])
              puts "ERROR: The --env-constraints and --expanded-run-list options require the --universe option to be set"
              exit!
            end
            if config[:timeout]
              msg("ERROR: The --timeout option requires the --env-constraints, --universe and --expanded-run-list options to be set")
              exit!
            end
            if config[:filter_universe]
              msg("ERROR: The --filter-universe option requires the --universe option and optionally the --env-constraints and/or --expanded-run-list options")
              exit!
            end
          end

          timeout = (config[:timeout].to_f * 1000).to_i if config[:timeout]
          timeout ||= 5 * 1000

          if config[:csv_universe_to_json]
            unless File.file?(config[:csv_universe_to_json])
              msg("ERROR: #{config[:csv_universe_to_json]} does not exist or is not a file.")
              exit!
            end
            universe = Hash.new { |hash, key| hash[key] = Hash.new }
            IO.foreach(config[:csv_universe_to_json]) do |line|
              name, version, updated_at, dependencies = line.split(",", 4)
              universe[name][version] = {updated_at: updated_at, dependencies: JSON.parse(dependencies)}
            end

            universe_json = JSON.pretty_generate(universe)
            universe_filename = "universe-#{Time.now.strftime("%Y-%m-%d-%H.%M.%S")}-#{Digest::SHA1.hexdigest(universe_json)}.txt"
            IO.write(universe_filename, universe_json)
            puts "Cookbook universe saved to #{universe_filename}"
            exit!
          end

          if config[:version_pin_cookbooks]
            unless File.file?(config[:version_pin_cookbooks])
              msg("ERROR: #{config[:version_pin_cookbooks]} does not exist or is not a file.")
              exit!
            end
            cookbooks = JSON.parse(IO.read(config[:version_pin_cookbooks]))
            version_pinned_cookbooks = Hash.new
            cookbooks.each do |cookbook_name, versions|
              max_version = versions.keys.max_by {|v| DepSelector::Version.new(v) }
              version_pinned_cookbooks[cookbook_name] = "= #{max_version}" if max_version
            end
            puts JSON.pretty_generate({name: "version-pinned-cookbooks", cookbook_versions: version_pinned_cookbooks})
            exit!
          end

          if config[:node]
            node = Chef::Node.load(config[:node])
          else
            node = Chef::Node.new
            node.name('depsolver-tmp-node')

            if config[:expanded_run_list]
              unless File.file?(config[:expanded_run_list])
                msg("ERROR: #{config[:expanded_run_list]} does not exist or is not a file.")
                exit!
              end
              contents = JSON.parse(IO.read(config[:expanded_run_list]))
              if !(contents.key?('expanded_run_list') && contents['expanded_run_list'].is_a?(Array))
                msg("ERROR: #{config[:expanded_run_list]} does not contain an expanded run list array.")
                exit!
              else
                expanded_run_list = contents['expanded_run_list']
                expanded_run_list.each do |arg|
                  node.run_list.add(arg)
                end
              end
            else
              run_list = name_args.map {|item| item.to_s.split(/,/) }.flatten.each{|item| item.strip! }
              run_list.delete_if {|item| item.empty? }

              run_list.each do |arg|
                node.run_list.add(arg)
              end
            end
          end

          # node.chef_environment must be set before expanding the run list in case the run list includes
          # roles with environment specific run lists
          node.chef_environment = config[:environment] if config[:environment]
          run_list_expansion = node.run_list.expand(node.chef_environment, 'server')
          expanded_run_list_with_versions = run_list_expansion.recipes.with_version_constraints_strings

          if config[:capture]
            if node.chef_environment == '_default'
              environment_cookbook_versions = Hash.new
            else
              environment_cookbook_versions = Chef::Environment.load(node.chef_environment).cookbook_versions
            end
            env = { name: node.chef_environment, cookbook_versions: environment_cookbook_versions }
            environment_constraints_json = JSON.pretty_generate(env)
            environment_constraints_filename = "#{node.chef_environment}-environment-#{Time.now.strftime("%Y-%m-%d-%H.%M.%S")}-#{Digest::SHA1.hexdigest(environment_constraints_json)}.txt"
            IO.write(environment_constraints_filename, environment_constraints_json)
            puts "Environment constraints saved to #{environment_constraints_filename}"

            begin
              universe = rest.get_rest("universe")
              universe_json = JSON.pretty_generate(universe)
              universe_filename = ""
              rest.url.to_s.match(".*/organizations/(.*)/?") { universe_filename = "#{$1}-" }
              universe_filename += "universe-#{Time.now.strftime("%Y-%m-%d-%H.%M.%S")}-#{Digest::SHA1.hexdigest(universe_json)}.txt"
              IO.write(universe_filename, universe_json)
              puts "Cookbook universe saved to #{universe_filename}"
            rescue Net::HTTPServerException
              puts "WARNING: The cookbook universe API endpoint is not available."
              puts "WARNING: Try capturing the cookbook universe using the SQL query found in the knife-depsolver README."
              puts "WARNING: Then convert the results using knife-depsolver's --csv-universe-to-json option"
            end
            exit
          end

          if config[:filter_universe]
            data = get_depsolver_data(node, expanded_run_list_with_versions, timeout)
            puts JSON.pretty_generate(filter_universe(data))
            exit!
          end

          depsolver_results = Hash.new
          if use_local_depsolver
            data = get_depsolver_data(node, expanded_run_list_with_versions, timeout)

            depsolver_start_time = Time.now

            solution = solve(data)

            depsolver_finish_time = Time.now

            if solution.first == :ok
              solution.last.map { |ckbk| ckbk_name, ckbk_version = ckbk; depsolver_results[ckbk_name] = ckbk_version.join('.') }
            else
              status, error_type, error_detail = solution
              depsolver_error = { error_type => error_detail }
            end
          else
            begin
              chef_server_version = rest.get(server_url.sub(/organizations.*/, 'version')).split("\n")[0]
            rescue Net::HTTPServerException
              chef_server_version = "unknown"
            end

            depsolver_start_time = Time.now

            ckbks = rest.post_rest("environments/" + node.chef_environment + "/cookbook_versions", { "run_list" => expanded_run_list_with_versions })

            depsolver_finish_time = Time.now

            ckbks.each do |name, ckbk|
              version = ckbk.is_a?(Hash) ? ckbk['version'] : ckbk.version
              depsolver_results[name] = version
            end
          end
        rescue Net::HTTPServerException => e
          api_error = {}
          api_error[:error_code] = e.response.code
          api_error[:error_message] = e.response.message
          begin
            api_error[:error_body] = JSON.parse(e.response.body)
          rescue JSON::ParserError
          end
        rescue => e
          msg("ERROR: #{e.message}")
          exit!
        ensure
          local_software = Hash.new
          %w(chef-dk chef dep_selector).each do |gem_name|
            begin
              local_software[gem_name] = Gem::Specification.find_by_name(gem_name).version
            rescue Gem::MissingSpecError
            end
          end

          results = {}
          results[:local_software] = local_software unless local_software.empty?
          if use_local_depsolver
            results[:depsolver] = "used local depsolver"
          else
            results[:depsolver] = {"used chef server" => chef_server_version} unless chef_server_version.nil?
          end
          results[:node] = node.name unless node.nil? || node.name.nil?
          results[:environment] = node.chef_environment unless node.chef_environment.nil?
          results[:run_list] = node.run_list unless node.nil? || node.run_list.nil?
          results[:expanded_run_list] = expanded_run_list_with_versions unless expanded_run_list_with_versions.nil?
          results[:depsolver_results] = depsolver_results unless depsolver_results.nil? || depsolver_results.empty?
          results[:depsolver_cookbook_count] = depsolver_results.count unless depsolver_results.nil? || depsolver_results.empty?
          results[:depsolver_elapsed_ms] = ((depsolver_finish_time - depsolver_start_time) * 1000).to_i unless depsolver_finish_time.nil?
          results[:depsolver_error] = depsolver_error unless depsolver_error.nil?
          results[:api_error] = api_error unless api_error.nil?

          if config[:capture]
            results_json = JSON.pretty_generate(results)
            expanded_run_list_filename = "expanded-run-list-#{Time.now.strftime("%Y-%m-%d-%H.%M.%S")}-#{Digest::SHA1.hexdigest(results_json)}.txt"
            IO.write(expanded_run_list_filename, results_json)
            puts "Expanded run list saved to #{expanded_run_list_filename}"
          else
            msg(JSON.pretty_generate(results))
          end
        end
      end

      def get_depsolver_data(node, expanded_run_list_with_versions, timeout)
        if config[:env_constraints]
          unless File.file?(config[:env_constraints])
            msg("ERROR: #{config[:env_constraints]} does not exist or is not a file.")
            exit!
          end
          env = JSON.parse(IO.read(config[:env_constraints]))
          if env['name'].to_s.empty?
            msg("ERROR: #{config[:env_constraints]} does not contain an environment name.")
            exit!
          else
            node.chef_environment = env['name']
          end
          if !env['cookbook_versions'].is_a?(Hash)
            msg("ERROR: #{config[:env_constraints]} does not contain a Hash of cookbook version constraints.")
            exit!
          else
            environment_cookbook_versions = env['cookbook_versions']
          end
        else
          environment_cookbook_versions = Hash.new
        end

        env_ckbk_constraints = environment_cookbook_versions.map do |ckbk_name, ckbk_constraint|
          [ckbk_name, ckbk_constraint.split.reverse].flatten
        end

        unless File.file?(config[:universe])
          msg("ERROR: #{config[:universe]} does not exist or is not a file.")
          exit!
        end
        universe = JSON.parse(IO.read(config[:universe]))
        if !universe.is_a?(Hash)
          msg("ERROR: #{config[:universe]} does not contain a cookbook universe Hash.")
          exit!
        end

        all_versions = universe.map do |ckbk_name, ckbk_metadata|
          ckbk_versions = ckbk_metadata.map do |version, version_metadata|
            [version, version_metadata['dependencies'].map { |dep_ckbk_name, dep_ckbk_constraint| [dep_ckbk_name, dep_ckbk_constraint.split.reverse].flatten }]
          end
          [ckbk_name, ckbk_versions]
        end

        expanded_run_list_with_split_versions = expanded_run_list_with_versions.map do |run_list_item|
          name, version = run_list_item.split('@')
          name.sub!(/::.*/, '')
          version ? [name, version] : name
        end

        depsolver_data = {environment_constraints: env_ckbk_constraints, all_versions: all_versions, run_list: expanded_run_list_with_split_versions, timeout_ms: timeout}
        depsolver_data
      end

      def filter_universe(data)
          # create dependency graph from cookbooks
          graph = DepSelector::DependencyGraph.new

          env_constraints = data[:environment_constraints].inject({}) do |acc, env_constraint|
            name, version, constraint = env_constraint
            acc[name] = DepSelector::VersionConstraint.new(constraint_to_str(constraint, version))
            acc
          end

          all_versions = []

          data[:all_versions].each do | vsn|
            name, version_constraints = vsn
            version_constraints.each do |version_constraint| # todo: constraints become an array in ruby
              # due to the erlectricity conversion from
              # tuples
              version, constraints = version_constraint

              # filter versions based on environment constraints
              env_constraint = env_constraints[name]
              if (!env_constraint || env_constraint.include?(DepSelector::Version.new(version)))
                package_version = graph.package(name).add_version(DepSelector::Version.new(version))
                constraints.each do |package_constraint|
                  constraint_name, constraint_version, constraint = package_constraint
                  version_constraint = DepSelector::VersionConstraint.new(constraint_to_str(constraint, constraint_version))
                  dependency = DepSelector::Dependency.new(graph.package(constraint_name), version_constraint)
                  package_version.dependencies << dependency
                end
              end
            end

            # regardless of filter, add package reference to all_packages
            all_versions << graph.package(name)
          end

          run_list = data[:run_list].map do |run_list_item|
            item_name, item_constraint_version, item_constraint = run_list_item
            version_constraint = DepSelector::VersionConstraint.new(constraint_to_str(item_constraint,
            item_constraint_version))
            DepSelector::SolutionConstraint.new(graph.package(item_name), version_constraint)
          end

          timeout_ms = data[:timeout_ms]
          selector = DepSelector::Selector.new(graph, (timeout_ms / 1000.0))

          if run_list.empty?
            constrained_cookbook_set = selector.dep_graph.packages.values
          else
            constrained_cookbook_set = selector.send(:trim_unreachable_packages, selector.dep_graph, run_list)
          end
          filtered_universe = Hash.new { |h,k| h[k] = Hash.new { |h,k| h[k] = Hash.new { |h,k| h[k] = Hash.new } } }
          constrained_cookbook_set.each do |ckbk|
            ckbk.versions.each do |ckbk_version|
              filtered_universe[ckbk.name][ckbk_version.version]["dependencies"] = Hash.new
              ckbk_version.dependencies.each do |ckbk_version_dep|
                constraint = ckbk_version_dep.constraint
                constraint_version = constraint.missing_patch_level ? "#{constraint.version.major}.#{constraint.version.minor}" : "#{constraint.version}"
                filtered_universe[ckbk.name][ckbk_version.version]["dependencies"][ckbk_version_dep.package.name] = "#{constraint.op} #{constraint_version}"
              end
            end
          end
          filtered_universe
      end
    end
  end
end
