class GitlabTokensController < ApplicationController
  before_action :authenticate_user!
  before_action :set_gitlab_token, only: [:edit, :update, :destroy]

  def new
    @gitlab_token = current_user.gitlab_token || current_user.build_gitlab_token
    if @gitlab_token.new_record?
      @gitlab_token.endpoint ||= "https://gitlab.com/api/v4"
    else
      # If token already exists, redirect to edit
      redirect_to edit_gitlab_token_path(repository_id: params[:repository_id])
      return
    end
    @repository = current_user.repositories.find(params[:repository_id]) if params[:repository_id]
  end

  def create
    Rails.logger.info "=== GitLab Token Create Action ==="
    Rails.logger.info "Params: #{params.inspect}"
    Rails.logger.info "Token params: #{gitlab_token_params.inspect}"
    
    @gitlab_token = current_user.build_gitlab_token(gitlab_token_params)
    Rails.logger.info "Token valid?: #{@gitlab_token.valid?}"
    Rails.logger.info "Token errors: #{@gitlab_token.errors.full_messages}" unless @gitlab_token.valid?
    
    if @gitlab_token.save
      # Validate the token
      connector = Repositories::GitlabConnector.new(@gitlab_token)
      validation = connector.validate_connection
      
      if validation[:success]
        redirect_path = params[:repository_id] ? 
          gitlab_projects_path(repository_id: params[:repository_id]) : 
          repositories_path
        redirect_to redirect_path, notice: "GitLab token configured successfully. Connected as #{validation[:user][:username]}"
      else
        @gitlab_token.destroy
        @repository = current_user.repositories.find(params[:repository_id]) if params[:repository_id]
        flash.now[:alert] = "Invalid GitLab token: #{validation[:errors].join(', ')}"
        render :new, status: :unprocessable_entity
      end
    else
      @repository = current_user.repositories.find(params[:repository_id]) if params[:repository_id]
      render :new, status: :unprocessable_entity
    end
  end

  def edit
    @repository = current_user.repositories.find(params[:repository_id]) if params[:repository_id]
  end

  def update
    # Store the new token temporarily
    @gitlab_token.token = gitlab_token_params[:token] if gitlab_token_params[:token].present?
    
    if @gitlab_token.update(gitlab_token_params.except(:token))
      # Validate the updated token
      connector = Repositories::GitlabConnector.new(@gitlab_token)
      validation = connector.validate_connection
      
      if validation[:success]
        redirect_path = params[:repository_id] ? 
          gitlab_projects_path(repository_id: params[:repository_id]) : 
          repositories_path
        redirect_to redirect_path, notice: "GitLab token updated successfully"
      else
        flash.now[:alert] = "Invalid GitLab token: #{validation[:errors].join(', ')}"
        render :edit, status: :unprocessable_entity
      end
    else
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    @gitlab_token.destroy
    redirect_to repositories_path, notice: "GitLab token removed"
  end

  private

  def set_gitlab_token
    @gitlab_token = current_user.gitlab_token
    redirect_to new_gitlab_token_path, alert: "GitLab token not found" unless @gitlab_token
  end

  def gitlab_token_params
    params.require(:gitlab_token).permit(:endpoint, :token)
  end
end