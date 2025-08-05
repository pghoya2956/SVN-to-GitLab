module JobsHelper
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
  
  def job_status_icon(status)
    case status
    when 'pending'
      '<i class="bi bi-clock"></i>'
    when 'running'
      '<i class="bi bi-play-circle"></i>'
    when 'completed'
      '<i class="bi bi-check-circle"></i>'
    when 'failed'
      '<i class="bi bi-x-circle"></i>'
    when 'cancelled'
      '<i class="bi bi-slash-circle"></i>'
    else
      '<i class="bi bi-question-circle"></i>'
    end
  end
  
  def format_duration(started_at, completed_at)
    return 'N/A' unless started_at
    
    end_time = completed_at || Time.current
    duration = end_time - started_at
    
    hours = (duration / 3600).to_i
    minutes = ((duration % 3600) / 60).to_i
    seconds = (duration % 60).to_i
    
    if hours > 0
      "#{hours}h #{minutes}m #{seconds}s"
    elsif minutes > 0
      "#{minutes}m #{seconds}s"
    else
      "#{seconds}s"
    end
  end
  
  def format_file_size(bytes)
    return 'N/A' unless bytes
    
    units = ['B', 'KB', 'MB', 'GB', 'TB']
    index = 0
    size = bytes.to_f
    
    while size >= 1024 && index < units.length - 1
      size /= 1024
      index += 1
    end
    
    "#{size.round(2)} #{units[index]}"
  end
end