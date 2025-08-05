module Repositories
  class GitlabConnector
    attr_reader :client, :errors

    def initialize(gitlab_token)
      @gitlab_token = gitlab_token
      @errors = []
      initialize_client
    end

    def fetch_personal_projects(page: 1, per_page: 20)
      return error_response("GitLab client not initialized") unless @client

      begin
        projects = @client.projects(
          owned: true,
          order_by: 'last_activity_at',
          sort: 'desc',
          page: page,
          per_page: per_page
        )
        
        format_projects_response(projects, page: page, per_page: per_page)
      rescue Gitlab::Error => e
        error_response("Failed to fetch personal projects: #{e.message}")
      end
    end

    def fetch_group_projects(page: 1, per_page: 20)
      return error_response("GitLab client not initialized") unless @client

      begin
        # Instead of fetching all groups (which can cause 500 errors),
        # fetch all projects the user has access to and filter by group
        projects = @client.projects(
          membership: true,  # Only projects the user is a member of
          order_by: 'last_activity_at',
          sort: 'desc',
          page: page,
          per_page: per_page
        )
        
        # Filter to only include group projects (exclude personal projects)
        group_projects = projects.select { |p| p.namespace.kind == 'group' }
        
        format_projects_response(group_projects, page: page, per_page: per_page)
      rescue Gitlab::Error => e
        # If the above fails, try a simpler approach
        begin
          # Just get all accessible projects without filtering
          all_projects = @client.projects(
            order_by: 'last_activity_at',
            sort: 'desc',
            page: page,
            per_page: per_page
          )
          
          format_projects_response(all_projects, page: page, per_page: per_page)
        rescue Gitlab::Error => fallback_error
          error_response("Failed to fetch group projects: #{fallback_error.message}")
        end
      end
    end

    def fetch_project(project_id)
      return error_response("GitLab client not initialized") unless @client

      begin
        project = @client.project(project_id)
        {
          success: true,
          project: format_project(project)
        }
      rescue Gitlab::Error => e
        error_response("Failed to fetch project: #{e.message}")
      end
    end

    def validate_connection
      return error_response("GitLab client not initialized") unless @client

      begin
        user = @client.user
        {
          success: true,
          user: {
            id: user.id,
            username: user.username,
            name: user.name,
            email: user.email
          }
        }
      rescue Gitlab::Error => e
        error_response("Failed to validate connection: #{e.message}")
      end
    end

    def search_projects(query, page: 1, per_page: 20)
      return error_response("GitLab client not initialized") unless @client

      begin
        projects = @client.project_search(
          query,
          order_by: 'last_activity_at',
          sort: 'desc',
          page: page,
          per_page: per_page
        )
        
        format_projects_response(projects, page: page, per_page: per_page)
      rescue Gitlab::Error => e
        error_response("Failed to search projects: #{e.message}")
      end
    end

    private

    def initialize_client
      return unless @gitlab_token

      begin
        @client = Gitlab.client(
          endpoint: @gitlab_token.endpoint,
          private_token: @gitlab_token.decrypt_token
        )
      rescue => e
        @errors << "Failed to initialize GitLab client: #{e.message}"
        @client = nil
      end
    end

    def format_projects_response(projects, page: 1, per_page: 20)
      # Handle both paginated response objects and plain arrays
      if projects.respond_to?(:total_count)
        {
          success: true,
          projects: format_projects(projects),
          total_count: projects.total_count,
          page: projects.current_page,
          per_page: projects.per_page
        }
      else
        # For plain arrays, we estimate pagination
        projects_array = projects.is_a?(Array) ? projects : projects.to_a
        {
          success: true,
          projects: format_projects(projects_array),
          total_count: projects_array.size,
          page: page,
          per_page: per_page
        }
      end
    end

    def format_projects(projects)
      projects.map { |project| format_project(project) }
    end

    def format_project(project)
      {
        id: project.id,
        name: project.name,
        path: project.path,
        path_with_namespace: project.path_with_namespace,
        description: project.description,
        visibility: project.visibility,
        web_url: project.web_url,
        http_url_to_repo: project.http_url_to_repo,
        ssh_url_to_repo: project.ssh_url_to_repo,
        created_at: project.created_at,
        last_activity_at: project.last_activity_at,
        namespace: {
          id: project.namespace.id,
          name: project.namespace.name,
          path: project.namespace.path,
          kind: project.namespace.kind
        }
      }
    end

    def error_response(message)
      @errors << message
      {
        success: false,
        errors: @errors
      }
    end
  end
end