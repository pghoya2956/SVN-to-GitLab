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
  
  # Job phase progress helpers
  def phase_status_class(job, phase_key)
    return 'completed' if phase_completed?(job, phase_key)
    return 'current' if phase_current?(job, phase_key)
    'pending'
  end

  def phase_completed?(job, phase_key)
    phases = Job::PHASES.keys
    current_index = phases.index(job.phase.to_sym)
    phase_index = phases.index(phase_key)
    
    return false unless current_index && phase_index
    
    if job.completed?
      true
    elsif job.phase == 'completed'
      true
    else
      phase_index < current_index
    end
  end

  def phase_current?(job, phase_key)
    job.phase.to_sym == phase_key && job.running?
  end
end