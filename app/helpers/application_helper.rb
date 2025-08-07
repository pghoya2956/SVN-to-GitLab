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
  
  # Authentication helper methods
  def user_signed_in?
    gitlab_authenticated?
  end
  
  # Job phase progress helpers
  def phase_status_class(job, phase_key)
    return 'completed' if phase_completed?(job, phase_key)
    return 'current' if phase_current?(job, phase_key)
    'pending'
  end

  def phase_completed?(job, phase_key)
    # pending 상태면 아무것도 완료되지 않음
    return false if job.phase.nil? || job.phase == 'pending'
    
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
    # pending이거나 phase가 없으면 cloning이 현재 단계
    if job.phase.nil? || job.phase == 'pending'
      return phase_key == :cloning && (job.running? || job.pending?)
    end
    job.phase.to_sym == phase_key && job.running?
  end
  
  # Render SVN directory tree structure
  def render_tree_structure(tree, level = 0)
    return '' unless tree.is_a?(Array)
    
    content = ''.html_safe
    tree.each_with_index do |entry, index|
      is_last = (index == tree.length - 1)
      
      # Tree symbols
      prefix = '  ' * level
      branch = is_last ? '└── ' : '├── '
      
      # Directory or file icon
      icon = entry[:type] == 'directory' ? '📁 ' : '📄 '
      
      # Build the line
      line = content_tag(:div, class: 'tree-line') do
        content = prefix.html_safe + branch.html_safe + icon.html_safe
        
        if entry[:type] == 'directory'
          # Make directories clickable for selection
          content += content_tag(:a, entry[:name], 
                                href: '#',
                                class: 'tree-dir-link text-decoration-none',
                                'data-path': entry[:path],
                                'data-action': 'click->layout-config#selectFromTree')
        else
          content += content_tag(:span, entry[:name], class: 'text-muted')
        end
        
        content
      end
      
      content += line
      
      # Recursively render children
      if entry[:children].present?
        content += render_tree_structure(entry[:children], level + 1)
      end
    end
    
    content
  end
end