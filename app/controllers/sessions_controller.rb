class SessionsController < ApplicationController
  skip_before_action :require_gitlab_auth
  
  def new
    # 로그인 페이지
  end
  
  def create
    token = params[:token]
    endpoint = params[:endpoint] || 'https://gitlab.com/api/v4'
    
    # URL 유효성 검증
    begin
      uri = URI.parse(endpoint)
      unless uri.is_a?(URI::HTTP) || uri.is_a?(URI::HTTPS)
        raise URI::InvalidURIError, "URL must be HTTP or HTTPS"
      end
    rescue URI::InvalidURIError => e
      flash.now[:alert] = "잘못된 GitLab URL 형식입니다. 올바른 URL을 입력해주세요. (예: https://gitlab.com/api/v4)"
      render :new, status: :unprocessable_entity
      return
    end
    
    # GitLab 인증 확인
    require 'gitlab'
    client = Gitlab.client(endpoint: endpoint, private_token: token)
    
    begin
      user_info = client.user
      
      # 세션에 저장
      session[:gitlab_token] = token
      session[:gitlab_endpoint] = endpoint
      session[:gitlab_user] = {
        id: user_info.id,
        username: user_info.username,
        email: user_info.email,
        name: user_info.name
      }
      session[:token_hash] = Digest::SHA256.hexdigest(token)
      
      redirect_to repositories_path, notice: "Logged in as #{user_info.username}"
    rescue Gitlab::Error::Unauthorized
      flash.now[:alert] = "Invalid GitLab Personal Access Token. Please check your token and try again."
      render :new, status: :unprocessable_entity
    rescue => e
      flash.now[:alert] = "Authentication failed: #{e.message}"
      render :new, status: :unprocessable_entity
    end
  end
  
  def destroy
    reset_session
    redirect_to login_path, notice: "Logged out successfully"
  end
end