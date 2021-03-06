require 'fileutils'

module Jekyll
  module OpenProjectHelpers

    DEFAULT_DOCS_SUBTREE = 'docs'

    DEFAULT_REPO_REMOTE_NAME = 'origin'
    DEFAULT_REPO_BRANCH = 'master'

    class NonLiquidDocument < Jekyll::Document
      def render_with_liquid?
        return false
      end
    end

    class CollectionDocReader < Jekyll::DataReader

      def read(dir, collection)
        read_project_subdir(dir, collection)
      end

      def read_project_subdir(dir, collection, nested=false)
        return unless File.directory?(dir) && !@entry_filter.symlink?(dir)

        entries = Dir.chdir(dir) do
          Dir["*.{adoc,md,markdown,html,svg,png}"] + Dir["*"].select { |fn| File.directory?(fn) }
        end

        entries.each do |entry|
          path = File.join(dir, entry)

          if File.directory?(path)
            read_project_subdir(path, collection, nested=true)

          elsif nested or (File.basename(entry, '.*') != 'index')
            ext = File.extname(path)
            if ['.adoc', '.md', '.markdown'].include? ext
              doc = NonLiquidDocument.new(path, :site => @site, :collection => collection)
              doc.read

              # Add document to Jekyll document database if it refers to software or spec
              # (as opposed to be some nested document like README)
              if doc.url.split('/').size == 4
                collection.docs << doc
              end
            else
              collection.files << Jekyll::StaticFile.new(
                @site,
                @site.source,
                Pathname.new(File.dirname(path)).relative_path_from(Pathname.new(@site.source)).to_s,
                File.basename(path),
                collection)
            end
          end
        end
      end
    end


    #
    # Below deals with fetching each open project’s data from its site’s repo
    # (such as posts, template includes, software and specs)
    # and reading it into 'projects' collection docs.
    #

    class OpenProjectReader < JekyllData::Reader

      # TODO: Switch to @site.config?
      @@siteconfig = Jekyll.configuration({})

      def read
        super
        if @site.config['is_hub']
          fetch_and_read_projects
        else
          fetch_and_read_software('software')
          fetch_and_read_specs('specs', true)
          fetch_hub_logo
        end
      end

      private

      def fetch_hub_logo
        if @site.config.key? 'parent_hub' and @site.config['parent_hub'].key? 'git_repo_url'
          parent_hub_repo_branch = @site.config['parent_hub']['git_repo_branch'] || DEFAULT_REPO_BRANCH
          git_shallow_checkout(
            File.join(@site.source, 'parent-hub'),
            @site.config['parent_hub']['git_repo_url'],
            parent_hub_repo_branch,
            ['assets', 'title.html'])
        end
      end

      def fetch_and_read_projects
        project_indexes = @site.collections['projects'].docs.select do |doc|
          pieces = doc.id.split('/')
          pieces.length == 4 and pieces[1] == 'projects' and pieces[3] == 'index'
        end
        project_indexes.each do |project|
          project_path = project.path.split('/')[0..-2].join('/')
          project_repo_url = project['site']['git_repo_url']
          project_repo_branch = project['site']['git_repo_branch'] || DEFAULT_REPO_BRANCH

          git_shallow_checkout(
            project_path,
            project_repo_url,
            project_repo_branch,
            ['assets', '_posts', '_software', '_specs'])

          CollectionDocReader.new(site).read(
            project_path,
            @site.collections['projects'])

          fetch_and_read_software('projects')
          fetch_and_read_specs('projects')
        end
      end

      def build_and_read_spec_pages(collection_name, index_doc, build_pages=false)
        item_name = index_doc.id.split('/')[-1]

        repo_checkout = nil
        src = index_doc.data['spec_source']
        repo_url = src['git_repo_url']
        repo_branch = src['git_repo_branch'] || DEFAULT_REPO_BRANCH
        repo_subtree = src['git_repo_subtree']
        build = src['build']
        engine = build['engine']
        engine_opts = build['options'] || {}

        spec_checkout_path = "#{index_doc.path.split('/')[0..-2].join('/')}/#{item_name}"
        spec_root = if repo_subtree
                      "#{spec_checkout_path}/#{repo_subtree}"
                    else
                      spec_checkout_path
                    end

        begin
          repo_checkout = git_shallow_checkout(spec_checkout_path, repo_url, repo_branch, [repo_subtree])
        rescue
          repo_checkout = nil
        end

        if repo_checkout
          if build_pages
            builder = Jekyll::OpenProjectHelpers::SpecBuilder::new(
              @site,
              index_doc,
              spec_root,
              "specs/#{item_name}",
              engine,
              engine_opts)

            builder.build()
            builder.built_pages.each do |page|
              @site.pages << page
            end

            CollectionDocReader.new(site).read(
              spec_checkout_path,
              @site.collections[collection_name])
          end

          index_doc.merge_data!({ 'last_update' => repo_checkout[:modified_at] })
        end
      end

      def fetch_and_read_specs(collection_name, build_pages=false)
        # collection_name would be either specs or (for hub site) projects

        return unless @site.collections.key?(collection_name)

        # Get spec entry points
        entry_points = @site.collections[collection_name].docs.select do |doc|
          doc.data['spec_source']
        end

        entry_points.each do |index_doc|
          build_and_read_spec_pages(collection_name, index_doc, build_pages)
        end
      end

      def fetch_and_read_software(collection_name)
        # collection_name would be either software or (for hub site) projects

        return unless @site.collections.key?(collection_name)

        entry_points = @site.collections[collection_name].docs.select do |doc|
          doc.data['repo_url']
        end

        entry_points.each do |index_doc|
          item_name = index_doc.id.split('/')[-1]

          docs = index_doc.data['docs']
          main_repo = index_doc.data['repo_url']

          sw_docs_repo = (if docs then docs['git_repo_url'] end) || main_repo
          sw_docs_branch = (if docs then docs['git_repo_branch'] end) || DEFAULT_REPO_BRANCH
          sw_docs_subtree = (if docs then docs['git_repo_subtree'] end) || DEFAULT_DOCS_SUBTREE

          docs_path = "#{index_doc.path.split('/')[0..-2].join('/')}/#{item_name}"

          begin
            sw_docs_checkout = git_shallow_checkout(docs_path, sw_docs_repo, sw_docs_branch, [sw_docs_subtree])
          rescue
            sw_docs_checkout = nil 
          end

          if sw_docs_checkout
            CollectionDocReader.new(site).read(
              docs_path,
              @site.collections[collection_name])
          end

          # Get last repository modification timestamp.
          # Fetch the repository for that purpose,
          # unless it’s the same as the repo where docs are.
          if sw_docs_checkout == nil or sw_docs_repo != main_repo
            repo_path = "#{index_doc.path.split('/')[0..-2].join('/')}/_#{item_name}_repo"
            repo_checkout = git_shallow_checkout(repo_path, DEFAULT_REPO_BRANCH, main_repo)
            index_doc.merge_data!({ 'last_update' => repo_checkout[:modified_at] })
          else
            index_doc.merge_data!({ 'last_update' => sw_docs_checkout[:modified_at] })
          end
        end
      end

      def git_shallow_checkout(repo_path, remote_url, remote_branch, sparse_subtrees=[])
        # Returns hash with timestamp of latest repo commit
        # and boolean signifying whether new repo has been initialized
        # in the process of pulling the data.

        newly_initialized = false
        repo = nil

        git_dir = File.join(repo_path, '.git')
        git_info_dir = File.join(git_dir, 'info')
        git_sparse_checkout_file = File.join(git_dir, 'info', 'sparse-checkout')
        unless File.exists? git_dir
          newly_initialized = true

          repo = Git.init(repo_path)

          repo.config(
            'core.sshCommand',
            'ssh -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no')

          repo.add_remote(DEFAULT_REPO_REMOTE_NAME, remote_url)

          if sparse_subtrees.size > 0
            repo.config('core.sparseCheckout', true)

            FileUtils.mkdir_p git_info_dir
            open(git_sparse_checkout_file, 'a') { |f|
              sparse_subtrees.each { |path| f << "#{path}\n" }
            }
          end

        else
          repo = Git.open(repo_path)

        end

        refresh_condition = @@siteconfig['refresh_remote_data'] || 'last-resort'

        unless ['always', 'last-resort', 'skip'].include?(refresh_condition)
          raise RuntimeError.new('Invalid refresh_remote_data value in site’s _config.yml!')
        end

        if refresh_condition == 'always'
          repo.fetch(DEFAULT_REPO_REMOTE_NAME, { :depth => 1 })
          repo.reset_hard
          repo.checkout("#{DEFAULT_REPO_REMOTE_NAME}/#{remote_branch}", { :f => true })

        elsif refresh_condition == 'last-resort'
          begin
            repo.checkout("#{DEFAULT_REPO_REMOTE_NAME}/#{remote_branch}", { :f => true })
          rescue Exception => e
            if e.message.include? "Sparse checkout leaves no entry on working directory"
              # Supposedly, software docs are missing! No big deal.
              return {
                :success => false,
                :newly_initialized => nil,
                :modified_at => nil,
              }
            else
              repo.fetch(DEFAULT_REPO_REMOTE_NAME, { :depth => 1 })
              repo.checkout("#{DEFAULT_REPO_REMOTE_NAME}/#{remote_branch}", { :f => true })
            end
          end
        end

        latest_commit = repo.gcommit('HEAD')

        return {
          :success => true,
          :newly_initialized => newly_initialized,
          :modified_at => latest_commit.date,
        }
      end
    end

  end
end

Jekyll::Hooks.register :site, :after_init do |site|
  if site.theme  # TODO: Check theme name
    site.reader = Jekyll::OpenProjectHelpers::OpenProjectReader::new(site)
  end
end
