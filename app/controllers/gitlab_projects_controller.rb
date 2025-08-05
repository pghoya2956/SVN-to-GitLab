class GitlabProjectsController < ApplicationController
  before_action :authenticate_user!
  before_action :ensure_gitlab_token
  before_action :load_repository

  def index
    @connector = Repositories::GitlabConnector.new(current_user.gitlab_token)
    
    # Validate connection first
    validation = @connector.validate_connection
    unless validation[:success]
      flash[:alert] = validation[:errors].join(", ")
      redirect_to edit_repository_path(@repository)
      return
    end

    # Fetch projects
    @personal_projects = @connector.fetch_personal_projects(page: params[:personal_page] || 1)
    @group_projects = @connector.fetch_group_projects(page: params[:group_page] || 1)
    
    respond_to do |format|
      format.html
      format.turbo_stream
    end
  end

  def search
    @connector = Repositories::GitlabConnector.new(current_user.gitlab_token)
    
    if params[:query].present?
      @search_results = @connector.search_projects(params[:query], page: params[:page] || 1)
    else
      @search_results = { success: true, projects: [], total_count: 0 }
    end
    
    respond_to do |format|
      format.turbo_stream
    end
  end

  def select
    @connector = Repositories::GitlabConnector.new(current_user.gitlab_token)
    project_result = @connector.fetch_project(params[:project_id])
    
    if project_result[:success]
      @repository.update(
        gitlab_project_id: project_result[:project][:id],
        gitlab_project_path: project_result[:project][:path_with_namespace],
        gitlab_project_url: project_result[:project][:web_url]
      )
      
      redirect_to @repository, notice: "GitLab project selected successfully"
    else
      redirect_to gitlab_projects_path(repository_id: @repository.id), 
                  alert: project_result[:errors].join(", ")
    end
  end

  private

  def ensure_gitlab_token
    unless current_user.gitlab_token
      redirect_to new_gitlab_token_path(repository_id: params[:repository_id]), 
                  alert: "Please configure GitLab access token first"
    end
  end

  def load_repository
    @repository = current_user.repositories.find(params[:repository_id])
  rescue ActiveRecord::RecordNotFound
    redirect_to repositories_path, alert: "Repository not found"
  end
end