require 'date'

DEFAULT_ORG = "caicloud"
DEFAULT_REPO = "platform"

module GHI
  module Commands
    class Scrum < Command
      attr_accessor :web
      attr_accessor :reverse
      attr_accessor :quiet
      attr_accessor :exclude_pull_requests
      attr_accessor :pull_requests_only

      def options
        OptionParser.new do |opts|
          opts.banner = 'usage: ghi scrum [options]'

          opts.separator ''
          opts.separator 'Scopes'
          opts.separator ''
          @repo = nil
          assigns[:org] = DEFAULT_ORG
          opts.on(
            '-O', '--org <organization>',
            "(default #{DEFAULT_ORG}) in repos within an organization you belong to"
          ) do |org|
            assigns[:org] = org
          end
          opts.on(
            '-r', '--repo <repo>',
            "(default #{DEFAULT_REPO}) in repos <repo>"
          ) do |repo|
            @repo = "#{assigns[:org]}/#{repo}"
            assigns[:org] = nil
          end
          opts.on(
            '-j', '--project <project>',
            "in project, <project> or Platform-<project>, only work for #{DEFAULT_ORG}"
          ) do |project|
            assigns[:org] = DEFAULT_ORG
            assigns[:project] = project
          end
          opts.on '--current-repo', 'only in current repo' do
            remove_instance_variable :@repo
            assigns[:org] = nil
          end

          opts.separator ''
          opts.separator 'Labels - scrum/*'
          opts.separator ''
          assigns[:base_labels] = ["scrum/kr"]
          opts.on('-k', '--key-result', '(default) baseType: list only scrum/kr') do
            assigns[:base_labels] = ["scrum/kr"]
          end
          opts.on('-t', '--task', 'baseType: list only scrum/task') do
            assigns[:base_labels] = ["scrum/task"]
          end
          opts.on('--all-type', 'all types') do
            assigns[:base_labels] = []
          end
          opts.on('-n', '--new', 'filter baseType with scrum/new') do
            (assigns[:labels] ||= []).concat ["scrum/new"]
          end
          opts.on('-d', '--delay', 'filter baseType with scrum/delay') do
            (assigns[:labels] ||= []).concat ["scrum/delay"]
          end
          opts.on('-D', '--done', 'filter baseType with scrum/done') do
            (assigns[:labels] ||= []).concat ["scrum/done"]
          end
          opts.on(
            '-L', '--label <labelname>...', Array, 'filter with extra label(s)'
          ) do |labels|
            (assigns[:labels] ||= []).concat labels
          end
          opts.on(
            '-N', '--not-label <labelname>...', Array, 'exclude with label(s)'
          ) do |labels|
            (assigns[:exclude_labels] ||= []).concat labels
          end

          opts.separator ''
          opts.separator 'People'
          opts.separator ''
          opts.on(
            '-f', '--filter <by>',
            filters = %w[all assigned created mentioned subscribed],
            Hash[filters.map { |f| [f[0, 1], f] }],
            filters.map { |f| "'#{f}'" }.join(', ')
          ) do |filter|
            assigns[:filter] = filter
          end
          opts.on '-a', '--all', 'all issues' do
            assigns[:filter] = 'all'
          end
          opts.on '--mine', 'assigned to you' do
            assigns[:filter] = 'assigned'
            assigns[:assignee] = Authorization.username
          end
          opts.on(
            '-u', '--[no-]assignee [<user>]', 'assigned to specified user'
          ) do |assignee|
            assignee = assignee.sub /^@/, '' if assignee
            assigns[:assignee] = any_or_none_or assignee
          end
          opts.on(
            '--creator [<user>]', 'created by you or specified user'
          ) do |creator|
            creator = creator.sub /^@/, '' if creator
            assigns[:creator] = creator || Authorization.username
          end
          opts.on(
            '-U', '--mentioned [<user>]', 'mentioning you or specified user'
          ) do |mentioned|
            assigns[:mentioned] = mentioned || Authorization.username
          end

          opts.separator ''
          opts.separator 'Common filters'
          opts.separator ''
          opts.on(
            '-s', '--state <in>', %w(open closed),
            {'o'=>'open', 'c'=>'closed'}, "'open' or 'closed'"
          ) do |state|
            assigns[:state] = state
          end
          opts.on(
            '-S', '--sort <by>', %w(created updated comments),
            {'c'=>'created','u'=>'updated','m'=>'comments'},
            "'created', 'updated', or 'comments'"
          ) do |sort|
            assigns[:sort] = sort
          end
          opts.on '--reverse', 'reverse (ascending) sort order' do
            self.reverse = !reverse
          end
          opts.on(
            '--since <date>', 'issues more recent than',
            "e.g., '2011-04-30'"
          ) do |date|
            begin
              assigns[:since] = DateTime.parse date # TODO: Better parsing.
            rescue ArgumentError => e
              raise OptionParser::InvalidArgument, e.message
            end
          end
          opts.on('-p', '--pulls','list only pull requests') { self.pull_requests_only = true }
          self.exclude_pull_requests = true
          opts.on('-P', '--no-pulls','(default) exclude pull requests') { self.exclude_pull_requests = true }
          opts.on(
            '-M', '--[no-]milestone [<n>]', Integer,
            'with (specified) milestone'
          ) do |milestone|
            assigns[:milestone] = any_or_none_or milestone
          end

          opts.separator ''
          opts.separator 'Display formats'
          opts.separator ''
          opts.on(
            '--no-labels', 'do not print labels'
          ) do
            assigns[:dont_print_labels] = true
          end
          opts.on(
            '-m', '--by-milestone', 'group by milestone'
          ) do
            assigns[:by_m] = true
          end
          opts.on('-v', '--verbose') { self.verbose = true }
          # FIXME --web is not working
          opts.on('-w', '--web') { self.web = true }

          opts.separator ''
        end
      end

      def execute
        if index = args.index { |arg| /^@/ === arg }
          assigns[:assignee] = args.delete_at(index)[1..-1]
        end

        begin
          options.parse! args
          @repo ||= ARGV[0] if ARGV.one?
        rescue OptionParser::InvalidOption => e
          fallback.parse! e.args
          retry
        end
        assigns[:labels] = (assigns[:base_labels].concat assigns[:labels] || []).join ','
        if assigns[:exclude_labels]
          assigns[:exclude_labels] = assigns[:exclude_labels].join ','
        end
        if reverse
          assigns[:sort] ||= 'created'
          assigns[:direction] = 'asc'
        end

        # nothing really happends since v3 API does not support project
        if assigns[:project]
          projects = api.get project_uri, {}, :preview => true
          project_num = nil
          project_name = nil
          # scan exact match first
          projects.body.each do |j|
            if j["name"].downcase == assigns[:project].downcase
              project_num = j["number"]
              project_name = j["name"]
            end
          end
          # scan platform-* match second
          project_num.nil? and projects.body.each do |j|
            if j["name"].downcase == "platform-#{assigns[:project].downcase}"
              project_num = j["number"]
              project_name = j["name"]
            end
          end
          # scan substring match second
          project_num.nil? and projects.body.each do |j|
            if j["name"].downcase.include? assigns[:project].downcase
              project_num = j["number"]
              project_name = j["name"]
            end
          end
          assigns[:project] = "#{assigns[:org]}/#{project_num}"
          assigns[:project_name] = project_name
        end

        if web
          Web.new(repo || 'dashboard').open 'issues', assigns
        else
          assigns[:per_page] = 100
          unless quiet
            print header = format_issues_header
            print "\n" unless paginate?
          end
          res = throb(
            0, format_state(assigns[:state], quiet ? CURSOR[:up][1] : '#')
          ) { api.get uri, assigns }
          print "\r#{CURSOR[:up][1]}" if header && paginate?
          page header do
            issues = res.body

            if exclude_pull_requests || pull_requests_only
              prs, issues = issues.partition { |i| i.key?('pull_request') }
              issues = prs if pull_requests_only
            end
            if assigns[:exclude_labels]
              issues = issues.reject  do |i|
                i["labels"].any? do |label|
                  assigns[:exclude_labels].include? label["name"]
                end
              end
            end
            if verbose
              puts issues.map { |i| format_issue i }
            else
              if assigns[:by_m]
                puts format_issues_by_milestone(issues, repo.nil?)
              else
                puts format_issues(issues, repo.nil?)
              end
            end
            break unless res.next_page
            res = throb { api.get res.next_page }
          end
        end
      rescue Client::Error => e
        if e.response.code == '422'
          e.errors.any? { |err|
            err['code'] == 'missing' && err['field'] == 'milestone'
          } and abort 'No such milestone.'
        end

        raise
      end

      private

      def project_uri
        url = ''
        if assigns[:org]
          url = "/orgs/#{assigns[:org]}"
        end
        return url << '/projects'
      end

      def uri
        url = ''
        if repo
          url = "/repos/#{repo}"
        end
        if assigns[:org]
          url = "/orgs/#{assigns[:org]}"
        end
        return url << '/issues'
      end

      def fallback
        OptionParser.new do |opts|
          opts.on('-c', '--closed') { assigns[:state] = 'closed' }
          opts.on('-q', '--quiet')  { self.quiet = true }
        end
      end
    end
  end
end
