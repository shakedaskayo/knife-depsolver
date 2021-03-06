## knife-depsolver

Knife plugin that calculates Chef cookbook dependencies for a given run_list.

Some features of knife-depsolver:

1. Able to capture all relevant information and use Chef DK's embedded depsolver.
2. JSON output for easy parsing
3. API error handling provides very helpful information
4. Accepts cookbook version constraints directly in the run_list
5. Useful information such as environment cookbook version constraints, expanded run_list and elapsed time for depsolver request
6. Ordering of depsolver results is maintained rather than sorted so you see what really gets passed to the chef-client

### How Does Cookbook Dependency Solving Work?

During a chef-client run the chef-client expands the node's run_list which means the chef-client recursively expands
any existing role run_lists until the expanded run_list only consists of a list of cookbook recipes.

Then chef-client sends the expanded run_list to the Chef Server's `/organizations/ORGNAME/environments/ENVNAME/cookbook_versions`
API endpoint which is serviced by opscode-erchef.

opscode-erchef gets the ORGNAME organization's cookbook universe (cookbook dependency info for every version of every cookbook)
and the ENVNAME environment's cookbook version constraints from the database.

opscode-erchef sends the expanded run_list, environment constraints and cookbook universe to a ruby process running the
[depselector.rb script](https://github.com/chef/chef-server/blob/12.9.1/src/oc_erchef/apps/chef_objects/priv/depselector_rb/depselector.rb).

This script uses the [dep_selector gem](https://github.com/chef/dep-selector) to build a dependency graph that filters out any
cookbook versions that don't satisfy the environment cookbook version constraints.

The dep_selector gem re-formulates the dependency graph and the solution constraints as a CSP and off-loads the hard work to
[Gecode](http://www.gecode.org/), a fast, license-friendly solver written in C++. If Gecode returns a solution then that is used by
opscode-erchef to send a list of cookbook file metadata back to the chef-client so it can synchronize its cookbook cache.

### Install

```
chef gem install knife-depsolver
```

*Currently NOT compatible with Windows Chef DK*

### Using knife-depsolver with Chef Server's depsolver

Find the depsolver solution for a node's run_list.

```
knife depsolver -n demo-node
```

Find the depsolver solution for an arbitrary run_list.
Specifying roles, recipes and even cookbook version constraints is allowed.

```
knife depsolver 'role[base],cookbook-B,cookbook-A::foo@3.1.4,cookbook-R'
```

The "-E <environment>" option can be added to use a specific environment's cookbook version constraints.

```
knife depsolver -E production -n demo-node
OR
knife depsolver -E production 'role[base],cookbook-B,cookbook-A::foo@3.1.4,cookbook-R'
```

### Using knife-depsolver with Chef DK's embedded depsolver

Mikael Lagerkvist is one of the authors of gecode, the constraint solver used by Chef's depsolver, and he says in the following mail list posts that "Debugging failures in constraint programs is unfortunately a very hard problem."

http://www.mail-archive.com/users@gecode.org/msg00110.html

https://www.mail-archive.com/users@gecode.org/msg00076.html

In the first post he goes on to talk about the importance of troubleshooting the whole problem set. With regards to the cookbook depsolver this translates to the importance of troubleshooting the whole run list. When troubleshooting a depsolver issue it is best to keep the run list the same and make changes to the environment cookbook version constraints or possibly to the cookbook universe.

knife-depsolver can provide many troubleshooting options by using the depsolver embedded in your workstation's Chef DK to make an identical calculation as the Chef Server.

#### Use the appropriate version of Chef DK

First, you need to make sure that your version of Chef DK is using the same version of the dep_selector gem as your version of Chef Server. If your Chef DK is using a different version of the dep_selector gem then knife-depsolver's calculations will not be identical to the Chef Server's calculations which will confuse troubleshooting efforts.

| dep_selector gem | Chef Server | Chef DK    |
| ---------------- | ----------- | ---------- |
| 1.0.3            | <= 12.8.0   | <= 0.16.28 |
| 1.0.4            | >= 12.9.0   | >= 0.17.17 |

#### --capture

Once you are sure you are using the correct version of Chef DK and you have installed the knife-depsolver plugin you can use the "--capture" option which queries the Chef Server and creates a separate file on the workstation for each of the following pieces of information.

1. environment cookbook version constraints
2. cookbook universe
3. expanded run list

The name of each file includes a creation timestamp and a SHA-1 checksum of the contents of the file. These can help during the troubleshooting process to make sure we know when the capture was done and whether anyone has modified the contents of the file.

For example:

```
knife depsolver -E production -n demo-node --capture
OR
knife depsolver -E production 'role[base],cookbook-B,cookbook-A::foo@3.1.4,cookbook-R' --capture
```

#### --env-constraints, --universe and --expanded-run-list

Now use the "--env-constraints", "--universe" and "--expanded-run-list" options to provide the information required for local depsolver calculations.

For example:

```
knife depsolver --expanded-run-list expanded-run-list-2017-05-01-18.52.40-387d90499514747792a805213c30be13d830d31f.txt --universe my-org-universe-2017-05-01-18.52.40-1c8e59e23530b1e1a8e0b3b3cc5236a29c84e469.txt --env-constraints production-environment-2017-05-01-18.52.40-5f5843d819ecb0b174f308d76d4336bb7bbfacbf.txt
```

This makes it easy to modify the input files to see the impact on the depsolver.

#### --timeout

Sometimes it can help to give the depsolver more than the default five seconds to perform its calculations. This can be done by using the "--timeout <seconds>" option to change the depsolver timeout.

```
knife depsolver --expanded-run-list expanded-run-list-2017-05-01-18.52.40-387d90499514747792a805213c30be13d830d31f.txt --universe my-org-universe-2017-05-01-18.52.40-1c8e59e23530b1e1a8e0b3b3cc5236a29c84e469.txt --env-constraints production-environment-2017-05-01-18.52.40-5f5843d819ecb0b174f308d76d4336bb7bbfacbf.txt --timeout 120
```

#### --filter-universe

Combine the --universe and the --filter-universe options with --env-constraints and/or --expanded-run-list options to filter the cookbook universe based on the environment cookbook version constraints and/or the expanded run list. This provides the ability to focus only on relevant information that would be sent to the depsolver without actually triggering the depsolver calculation. This is especially helpful when the depsolver isn't returning any results because it can't calculate a solution in a reasonable amount of time.

```
knife depsolver --expanded-run-list expanded-run-list-2017-05-01-18.52.40-387d90499514747792a805213c30be13d830d31f.txt --universe my-org-universe-2017-05-01-18.52.40-1c8e59e23530b1e1a8e0b3b3cc5236a29c84e469.txt --env-constraints production-environment-2017-05-01-18.52.40-5f5843d819ecb0b174f308d76d4336bb7bbfacbf.txt --filter-universe > filtered-universe.txt
```

Now you can review the output to see if you can find anything that could be causing problems for the depsolver. You can make changes to the input files to see the impact on the list of cookbooks that would be sent to the depsolver.

If necessary you could also use the results along with the --version-pin-cookbooks option to create an environment input file that pins a version for each cookbook. Then you can modify that set of version constraints and run the depsolver in an effort to get a solution in a reasonable amount of time or to isolate the problem.

#### --version-pin-cookbooks

The --version-pin-cookbooks option takes a filename as an argument. The file must be in the JSON format of a cookbook universe or filtered cookbook universe. The --version-pin-cookbooks option creates an environment JSON file with cookbook version constraints for that pin every cookbook to its latest version. This environment file can then be used with the --env-constraints option to provide a strictly constrained starting point when troubleshooting a depsolver issue.

```
knife depsolver --version-pin-cookbooks filtered-universe.txt > version-pinned-cookbooks.txt
```

#### /tmp/DepSelectorDebugOn

If you really want to enable the dep_selector gem's debug level output then you can simply create the `touch /tmp/DepSelectorDebugOn` file on your workstation's disk.

```
touch /tmp/DepSelectorDebugOn
```

### Chef Server < 12.4.0

knife-depsolver requires cookbook universe data in order to use Chef DK's embedded depsolver. The "/universe" API endpoint was added in the Chef Server 12.4.0 release.

If you are using a version of Chef Server older than 12.4.0 then you can run the following command on your Chef Server to extract the cookbook universe directly from the database in CSV format.

```
export ORGNAME=demo

cat <<EOF | chef-server-ctl psql opscode_chef --options '-tAF,' > universe.csv
SELECT cvd.name,
cvd.major || '.' || cvd.minor || '.' || cvd.patch AS version,
updated_at,
dependencies
FROM cookbook_version_dependencies cvd
INNER JOIN cookbooks ckbks
ON cvd.org_id = ckbks.org_id
AND cvd.name = ckbks.name
INNER JOIN cookbook_versions cv
ON ckbks.id = cv.cookbook_id
AND cvd.major = cv.major
AND cvd.minor = cv.minor
AND cvd.patch = cv.patch
WHERE cvd.org_id = (SELECT id
FROM orgs
WHERE name = '$ORGNAME'
LIMIT 1)
ORDER BY updated_at DESC;
EOF
```

Then you can run the following command to convert it to the normal JSON format.

```
knife depsolver --csv-universe-to-json universe.csv
```

If the Chef Server doesn't have the "chef-server-ctl psql" command available then you can try replacing that line with the following.

```
cat <<EOF | su -l opscode-pgsql -c 'psql opscode_chef -tAF,' > universe.csv
```
