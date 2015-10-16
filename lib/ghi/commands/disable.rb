module GHI
  module Commands
    class Disable < Command

			def execute
				require_repo
				patch_data = {}
				# TODO: A way to grap the actual repo name, rather than username/repo
				repo_path = repo.partition "/"
				patch_data[:name] = repo_path[2]
				patch_data[:has_issues] = false
				res = throb { api.patch "/repos/#{repo}", patch_data }.body
				if !res['has_issues']
					puts "Issues are now disabled for this repo"
				else
					puts "Something went wrong disabling issues for this repo"
				end
			end

		end
	end
end