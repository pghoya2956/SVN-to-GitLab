module ApplicationHelper
  def job_status_color(status)
    case status
    when 'pending'
      'secondary'
    when 'running'
      'primary'
    when 'completed'
      'success'
    when 'failed'
      'danger'
    when 'cancelled'
      'warning'
    else
      'secondary'
    end
  end
  
  # Devise helper methods override
  def user_signed_in?
    true
  end
  
  def current_user
    @current_user ||= User.first_or_create!(
      email: 'default@example.com',
      password: 'defaultpassword',
      password_confirmation: 'defaultpassword'
    )
  end
end