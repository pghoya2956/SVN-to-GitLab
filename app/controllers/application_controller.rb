class ApplicationController < ActionController::Base
  before_action :require_gitlab_auth
  helper_method :current_gitlab_user, :gitlab_client, :gitlab_authenticated?
  
  private
  
  def require_gitlab_auth
    unless gitlab_authenticated?
      redirect_to login_path, alert: "Please login with GitLab PAT"
    end
  end
  
  def gitlab_authenticated?
    session[:gitlab_token].present?
  end
  
  def current_gitlab_user
    session[:gitlab_user]
  end
  
  def current_token_hash
    session[:token_hash]
  end
  
  def gitlab_client
    @gitlab_client ||= Gitlab.client(
      endpoint: session[:gitlab_endpoint],
      private_token: session[:gitlab_token]
    ) if session[:gitlab_token]
  end
  
  # 임시 호환성 메서드
  def current_user
    OpenStruct.new(
      id: current_token_hash,
      email: current_gitlab_user&.dig(:email),
      gitlab_token: OpenStruct.new(
        decrypt_token: session[:gitlab_token],
        endpoint: session[:gitlab_endpoint]
      )
    ) if gitlab_authenticated?
  end
end