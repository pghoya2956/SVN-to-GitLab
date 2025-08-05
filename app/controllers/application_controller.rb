class ApplicationController < ActionController::Base
  before_action :set_default_user
  
  private
  
  def set_default_user
    # 인증 없이 기본 사용자 사용
    User.current = User.first_or_create!(
      email: 'default@example.com',
      password: 'defaultpassword',
      password_confirmation: 'defaultpassword'
    )
  end
  
  def current_user
    User.current
  end
  
  helper_method :current_user
end